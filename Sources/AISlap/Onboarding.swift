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
    private static let seenKey = "hasSeenWelcome"

    static var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    static func showIfFirstRun(then finished: @escaping () -> Void) {
        guard !hasSeen else { return }
        show(force: false, then: finished)
    }

    static func show(force: Bool, then finished: @escaping () -> Void) {
        hasSeen = true
        NSApp.activate(ignoringOtherApps: true)
        welcome()
        permissions()
        finished()
    }

    // MARK: - Steps

    private static func welcome() {
        let alert = NSAlert()
        alert.messageText = "Press ⌥Space on any window"
        alert.informativeText = """
            AI-slap takes a picture of whatever window you're looking at and drops it \
            into a new chat with your AI, so you can ask about it without describing it.

            You get to see the screenshot and type what you want before anything is sent. \
            Nothing is submitted for you, and nothing is recorded anywhere.

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

        alert.runModal()
        if let id = picker.selectedItem?.representedObject as? String {
            Handoff.preferredID = id
            Handoff.hasChosenDestination = true
        }
    }

    /// Both permissions, explained in terms of what breaks without them rather than in
    /// terms of what they are called in System Settings.
    private static func permissions() {
        let accessibility = AXIsProcessTrusted()
        let screen = WindowCapture.hasPermission
        if accessibility && screen { return }

        let alert = NSAlert()
        alert.messageText = "Two permissions and you're done"
        alert.informativeText = """
            \(accessibility ? "✓" : "•") Accessibility lets AI-slap paste into your AI app. \
            Without it the handoff stops at your clipboard and you press ⌘V yourself.

            \(screen ? "✓" : "•") Screen Recording lets it take the screenshot. \
            Without it handoffs go over as text only.

            macOS may ask you to quit and reopen AI-slap after you grant Accessibility. \
            That's normal.
            """
        if !accessibility { alert.addButton(withTitle: "Turn on Accessibility") }
        if !screen { alert.addButton(withTitle: "Turn on Screenshots") }
        alert.addButton(withTitle: accessibility || screen ? "Finish" : "Skip for now")

        let clicked = alert.runModal()
        let first = NSApplication.ModalResponse.alertFirstButtonReturn
        let wantsAccessibility = !accessibility && clicked == first
        let wantsScreen = !screen && clicked == (accessibility ? first : .alertSecondButtonReturn)

        if wantsAccessibility {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            )
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return  // The grant needs System Settings and often a relaunch; don't loop on it.
        }
        if wantsScreen {
            _ = WindowCapture.requestPermission()
            if !WindowCapture.hasPermission {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return
        }
    }
}
