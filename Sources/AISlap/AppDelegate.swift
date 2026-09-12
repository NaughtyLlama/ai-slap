import AppKit

/// The whole app: a hotkey, a screenshot, a chat window, and a crab.
///
/// There used to be a detection layer here — an observer, a rules engine, an on-device
/// personaliser and a local log of everything you looked at — built to notice moments
/// where you were doing something by hand that AI could have done. It worked, and over
/// four weeks it produced three useful interruptions. The screenshot was doing all the
/// work the whole time, so that is what the app is now.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menu: MenuBarController?
    private let hotkeys = GlobalHotkeys()
    private let doug = DougWindow()
    private var handoff: Handoff?
    private var hotkeyRegistered = false
    private var lastResult: Handoff.Result?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let handoff = Handoff(destinations: Destinations.load())
        self.handoff = handoff

        menu = MenuBarController(
            onHandoffNow: { [weak self] in self?.handoffNow() },
            onSetDestination: { [weak self] id in
                Handoff.preferredID = id
                Handoff.hasChosenDestination = true
                self?.doug.destinationName = self?.handoff?.preferredDestination?.name
                self?.refresh()
            },
            destinations: { [weak self] in
                guard let handoff = self?.handoff else { return [] }
                let active = handoff.preferredDestination?.id
                return handoff.availableDestinations.map {
                    (id: $0.id, name: $0.name, installed: $0.isNativeAvailable, active: $0.id == active)
                }
            },
            onToggleMascot: { [weak self] in
                MascotSettings.isEnabled.toggle()
                self?.doug.setEnabled(MascotSettings.isEnabled)
                self?.refresh()
            },
            onToggleCalmMode: { [weak self] in
                MascotSettings.calmMode.toggle()
                self?.doug.calmMode = MascotSettings.calmMode
                self?.refresh()
            },
            onToggleLaunchAtLogin: { [weak self] in self?.toggleLaunchAtLogin() },
            onFixPermission: { [weak self] in self?.openAccessibilitySettings() },
            onShowWelcome: { [weak self] in Onboarding.show(force: true) { self?.refresh() } },
            lastHandoff: { [weak self] in self?.lastResult?.summary }
        )

        doug.onHandoffGesture = { [weak self] in self?.handoffNow() }
        doug.calmMode = MascotSettings.calmMode
        doug.setEnabled(MascotSettings.isEnabled)
        doug.destinationName = handoff.preferredDestination?.name

        registerHotkeys()
        refresh()

        // First run explains the two permissions and asks which AI to use. Everything
        // works without answering it — the menu has the same choices — but arriving at
        // a menu-bar icon with no idea what it wants is how a shared build dies quietly.
        Onboarding.showIfFirstRun { [weak self] in
            self?.doug.destinationName = self?.handoff?.preferredDestination?.name
            self?.refresh()
        }
    }

    // MARK: - The handoff

    private func handoffNow() {
        guard let handoff, let app = NSWorkspace.shared.frontmostApplication else { return }
        let target = Handoff.Target(
            pid: app.processIdentifier,
            title: WindowCapture.focusedWindowTitle(pid: app.processIdentifier),
            prompt: HandoffRecovery.defaultPrompt
        )
        handoff.run(target) { [weak self] result in self?.report(result) }
    }

    /// Silence after a failed paste looks exactly like a broken app, so every path that
    /// leaves the user holding something says so.
    private func report(_ result: Handoff.Result) {
        lastResult = result
        switch result {
        case .pasteRequested:
            doug.celebrate()
        case .clipboardOnly:
            doug.reset()  // The recovery panel is already on screen saying what to do.
        case .cancelled:
            doug.reset()
        case .needsScreenRecording:
            doug.reset()
            let alert = NSAlert()
            alert.messageText = "Turn on screenshots, then try again"
            alert.informativeText = "Add AI-slap under Privacy & Security → Screen Recording. If macOS asks you to quit and reopen it, do that first. Handoffs still work as text without it."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        case .failed(let message):
            doug.reset()
            let alert = NSAlert()
            alert.messageText = "That handoff couldn't continue"
            alert.informativeText = message
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    // MARK: - Hotkeys

    /// ⌥Space hands off. ⌥⌘G hides Doug instantly, for screen shares.
    private func registerHotkeys() {
        hotkeyRegistered = hotkeys.register(id: GlobalHotkeys.handoffID, keyCode: 49, modifiers: 2048) {  // ⌥Space
            [weak self] in self?.handoffNow()
        }
        hotkeys.register(id: GlobalHotkeys.panicID, keyCode: 5, modifiers: 2048 | 256) { [weak self] in  // ⌥⌘G
            guard let self else { return }
            self.doug.isHidden ? self.doug.unhide() : self.doug.hide()
            self.refresh()
        }
    }

    // MARK: - Permissions and settings

    private func toggleLaunchAtLogin() {
        if let problem = LaunchAtLogin.set(!LaunchAtLogin.state.isOn) {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = problem
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        refresh()
    }

    private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Accessibility can be revoked at any moment, and after a rebuild it can vanish
    /// silently, so it is re-read on every menu refresh rather than cached at launch.
    private func refresh() {
        menu?.update(
            hasAccessibility: AXIsProcessTrusted(),
            hasScreenRecording: WindowCapture.hasPermission,
            hotkeyRegistered: hotkeyRegistered,
            mascotEnabled: MascotSettings.isEnabled,
            calmMode: MascotSettings.calmMode,
            dougHidden: doug.isHidden,
            launchAtLogin: LaunchAtLogin.state
        )
    }
}
