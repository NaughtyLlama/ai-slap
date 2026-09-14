import AppKit
import ApplicationServices

/// What someone sees the first time they open this, which for anyone but its author is
/// the only explanation they will ever get.
///
/// A menu-bar app that needs two system permissions before it can do anything is the
/// easiest kind of app to give up on: it launches, shows an icon, and then appears
/// broken. So the first run says what it does, asks where handoffs should go, and walks
/// both permissions rather than waiting to fail.
enum Onboarding {
    struct Permissions: Equatable {
        var accessibility: Bool
        var screen: Bool
        var complete: Bool { accessibility && screen }
    }

    enum Action { case accessibility, screen, skip }

    /// Persist incomplete setup across a Settings detour or a process restart.
    /// Effects are injected so tests never open dialogs or change system permissions.
    final class Flow {
        let defaults: UserDefaults
        let readPermissions: () -> Permissions
        let welcome: () -> Void
        let choose: (Permissions) -> Action
        let request: (Action) -> Void
        private var showing = false
        private var lastPermissions: Permissions?

        init(defaults: UserDefaults, readPermissions: @escaping () -> Permissions,
             welcome: @escaping () -> Void, choose: @escaping (Permissions) -> Action,
             request: @escaping (Action) -> Void) {
            self.defaults = defaults
            self.readPermissions = readPermissions
            self.welcome = welcome
            self.choose = choose
            self.request = request
        }

        var pending: Bool {
            get { defaults.object(forKey: "permissionSetupPending") as? Bool ?? true }
            set { defaults.set(newValue, forKey: "permissionSetupPending") }
        }

        func start(force: Bool = false) {
            guard !showing else { return }
            showing = true
            defer { showing = false }
            if force || !defaults.bool(forKey: "hasSeenWelcome") {
                welcome()
                defaults.set(true, forKey: "hasSeenWelcome")
                pending = true
            }
            if pending { advance() }
        }

        func resume() {
            guard pending, !showing, readPermissions() != lastPermissions else { return }
            start()
        }

        private func advance() {
            let state = readPermissions()
            lastPermissions = state
            if state.complete { pending = false; return }
            switch choose(state) {
            case .skip: pending = false
            case .accessibility: request(.accessibility)
            case .screen: request(.screen)
            }
        }
    }

    private static let flow = Flow(
        defaults: .standard,
        readPermissions: { Permissions(accessibility: AXIsProcessTrusted(), screen: WindowCapture.hasPermission) },
        welcome: { welcome() }, choose: { permissions($0) }, request: { request($0) }
    )

    static func showIfFirstRun(then finished: @escaping () -> Void) {
        flow.start()
        finished()
    }

    static func show(force: Bool, then finished: @escaping () -> Void) {
        flow.start(force: force)
        finished()
    }

    static func resumeIfNeeded() { flow.resume() }

    // MARK: - Steps

    static func makeWelcomeAlert() -> (NSAlert, NSPopUpButton) {
        let alert = NSAlert()
        alert.messageText = "Press ⌥Space on any window"
        alert.informativeText = """
            AI-slap takes a picture of whatever window you're looking at and drops it \
            into your AI app. In a browser, you paste the prompt and screenshot yourself.

            You get to see the screenshot and type what you want before anything is sent. \
            AI-slap never submits the chat or saves a screenshot history. Your chosen AI \
            receives anything you paste; its privacy settings apply.

            IT ALSO WATCHES WHICH WINDOW YOU'RE IN. If you've been stuck on the same \
            email or document for a while and haven't touched AI recently, Doug will \
            suggest handing it over. A handful of times a day at most, never while \
            you're on a call, never at night.

            That watching reads the name of your frontmost window to tell an email from \
            a spreadsheet. It is kept in memory, never written to disk, and gone when \
            you quit. There is no history, no learning, and nothing leaves your Mac. \
            Switch it off any time under "Watch and nudge me", or silence it for a \
            few hours with "Quiet for a while".

            Doug the hermit crab lives on your desktop. Drag him where you like. \
            Double-click him to hand off without touching the keyboard.
            """
        alert.addButton(withTitle: "Next")

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        let choices = Destinations.load().filter(\.isAvailable)
        for choice in choices {
            picker.addItem(withTitle: choice.isNativeAvailable ? choice.name : "\(choice.name) (in your browser)")
            picker.lastItem?.representedObject = choice.id
        }
        if let current = Handoff.preferredID ?? choices.first(where: \.isNativeAvailable)?.id ?? choices.first?.id,
           let index = picker.itemArray.firstIndex(where: { $0.representedObject as? String == current }) {
            picker.selectItem(at: index)
        }

        let label = NSTextField(labelWithString: "Send handoffs to:")
        let stack = NSStackView(views: [label, picker])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        alert.accessoryView = stack

        return (alert, picker)
    }

    private static func welcome() {
        let (alert, picker) = makeWelcomeAlert()
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if let id = picker.selectedItem?.representedObject as? String {
            Handoff.preferredID = id
            Handoff.hasChosenDestination = true
        }
    }

    /// Both permissions, explained in terms of what breaks without them rather than in
    /// terms of what they are called in System Settings.
    static func makePermissionsAlert(_ state: Permissions) -> NSAlert {
        let accessibility = state.accessibility
        let screen = state.screen
        let alert = NSAlert()
        alert.messageText = "Two permissions and you're done"
        alert.informativeText = """
            \(accessibility ? "✓" : "•") Accessibility lets AI-slap paste into your AI app. \
            Without it the handoff stops at your clipboard and you press ⌘V yourself.

            \(screen ? "✓" : "•") Screen Recording lets it take the screenshot. \
            Without it handoffs go over as text only.

            Enable each permission in System Settings. Return to AI-slap to continue. \
            If macOS asks you to quit and reopen, setup resumes when you reopen. \
            You can also return through menu bar → Set up AI-slap….
            """
        if !accessibility { alert.addButton(withTitle: "Turn on Accessibility") }
        if !screen { alert.addButton(withTitle: "Turn on Screenshots") }
        alert.addButton(withTitle: "Skip for now")

        return alert
    }

    private static func permissions(_ state: Permissions) -> Action {
        let accessibility = state.accessibility
        let screen = state.screen
        let alert = makePermissionsAlert(state)
        NSApp.activate(ignoringOtherApps: true)
        let clicked = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        let wantsAccessibility = !accessibility && clicked == first
        let wantsScreen = !screen && clicked == (accessibility ? first : .alertSecondButtonReturn)

        if wantsAccessibility { return .accessibility }
        if wantsScreen { return .screen }
        return .skip
    }

    private static func request(_ action: Action) {
        switch action {
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        case .screen:
            _ = WindowCapture.requestPermission()
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case .skip: break
        }
    }
}
