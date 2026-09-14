import AppKit

/// The menu. Small on purpose: a handoff, where it goes, whether it asks first, Doug,
/// and the two permissions that can stop any of it working.
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let handoffStatusItem = NSMenuItem()
    private let destinationItem = NSMenuItem()
    private let reviewItem = NSMenuItem()
    private let nudgeItem = NSMenuItem()
    private let snoozeItem = NSMenuItem()
    private let nudgeStatusItem = NSMenuItem()
    private let mascotItem = NSMenuItem()
    private let calmItem = NSMenuItem()
    private let hideDougItem = NSMenuItem()
    private let accessibilityItem = NSMenuItem()
    private let screenRecordingItem = NSMenuItem()
    private let launchItem = NSMenuItem()

    private let onHandoffNow: () -> Void
    private let onSetDestination: (String) -> Void
    private let destinations: () -> [(id: String, name: String, installed: Bool, active: Bool)]
    private let onToggleMascot: () -> Void
    private let onToggleCalmMode: () -> Void
    private let onToggleLaunchAtLogin: () -> Void
    private let onFixPermission: () -> Void
    private let onShowWelcome: () -> Void
    private let onToggleNudges: () -> Void
    private let onSnooze: (Int) -> Void
    private let onCancelSnooze: () -> Void
    private let lastHandoff: () -> String?

    init(
        onHandoffNow: @escaping () -> Void,
        onSetDestination: @escaping (String) -> Void,
        destinations: @escaping () -> [(id: String, name: String, installed: Bool, active: Bool)],
        onToggleMascot: @escaping () -> Void,
        onToggleCalmMode: @escaping () -> Void,
        onToggleLaunchAtLogin: @escaping () -> Void,
        onFixPermission: @escaping () -> Void,
        onShowWelcome: @escaping () -> Void,
        onToggleNudges: @escaping () -> Void,
        onSnooze: @escaping (Int) -> Void,
        onCancelSnooze: @escaping () -> Void,
        lastHandoff: @escaping () -> String?
    ) {
        self.onHandoffNow = onHandoffNow
        self.onSetDestination = onSetDestination
        self.destinations = destinations
        self.onToggleMascot = onToggleMascot
        self.onToggleCalmMode = onToggleCalmMode
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onFixPermission = onFixPermission
        self.onShowWelcome = onShowWelcome
        self.onToggleNudges = onToggleNudges
        self.onSnooze = onSnooze
        self.onCancelSnooze = onCancelSnooze
        self.lastHandoff = lastHandoff

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        statusItem.menu = menu
    }

    private func buildMenu() {
        let handoff = NSMenuItem(
            title: "Hand off this window", action: #selector(handoffNow), keyEquivalent: ""
        )
        handoff.target = self
        menu.addItem(handoff)

        handoffStatusItem.isEnabled = false
        menu.addItem(handoffStatusItem)

        destinationItem.title = "Send it to"
        destinationItem.submenu = NSMenu()
        menu.addItem(destinationItem)

        // Ticked means the handoff stops to show you the screenshot and let you say what
        // you want. Unticking it here is the way back from "don't ask again" in the
        // dialog, which is otherwise a one-way door.
        reviewItem.title = "Ask me before sending"
        reviewItem.target = self
        reviewItem.action = #selector(toggleReview)
        menu.addItem(reviewItem)

        menu.addItem(.separator())

        nudgeItem.title = "Watch and nudge me"
        nudgeItem.target = self
        nudgeItem.action = #selector(toggleNudges)
        menu.addItem(nudgeItem)

        nudgeStatusItem.isEnabled = false
        menu.addItem(nudgeStatusItem)

        snoozeItem.title = "Quiet for a while"
        let snoozeMenu = NSMenu()
        for minutes in [30, 60, 180] {
            let item = NSMenuItem(
                title: minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hour\(minutes > 60 ? "s" : "")",
                action: #selector(snooze(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = minutes
            snoozeMenu.addItem(item)
        }
        snoozeMenu.addItem(.separator())
        let wakeItem = NSMenuItem(title: "Never mind, carry on", action: #selector(cancelSnooze), keyEquivalent: "")
        wakeItem.target = self
        snoozeMenu.addItem(wakeItem)
        snoozeItem.submenu = snoozeMenu
        menu.addItem(snoozeItem)

        menu.addItem(.separator())

        let dougRoot = NSMenuItem(title: "Doug", action: nil, keyEquivalent: "")
        let dougMenu = NSMenu()
        mascotItem.title = "Show Doug"
        mascotItem.target = self
        mascotItem.action = #selector(toggleMascot)
        dougMenu.addItem(mascotItem)

        calmItem.title = "Calm mode — no wandering"
        calmItem.target = self
        calmItem.action = #selector(toggleCalmMode)
        dougMenu.addItem(calmItem)

        hideDougItem.title = "Hide him now (⌥⌘G)"
        hideDougItem.isEnabled = false
        dougMenu.addItem(hideDougItem)

        let dougHelp = NSMenuItem(
            title: "Drag to move him. Double-click to hand off.", action: nil, keyEquivalent: ""
        )
        dougHelp.isEnabled = false
        dougMenu.addItem(dougHelp)
        dougRoot.submenu = dougMenu
        menu.addItem(dougRoot)

        menu.addItem(.separator())

        accessibilityItem.target = self
        accessibilityItem.action = #selector(fixPermission)
        menu.addItem(accessibilityItem)

        screenRecordingItem.target = self
        screenRecordingItem.action = #selector(showWelcome)
        menu.addItem(screenRecordingItem)

        let welcome = NSMenuItem(
            title: "Set up AI-slap…", action: #selector(showWelcome), keyEquivalent: ""
        )
        welcome.target = self
        menu.addItem(welcome)

        menu.addItem(.separator())

        launchItem.target = self
        launchItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(launchItem)

        let quit = NSMenuItem(title: "Quit AI-slap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// The icon is the only part of this app most people will ever look at, so a missing
    /// permission has to be visible there rather than one click deep in a menu.
    func update(
        hasAccessibility: Bool,
        hasScreenRecording: Bool,
        hotkeyRegistered: Bool,
        nudgesEnabled: Bool,
        nudgeStatus: String,
        mascotEnabled: Bool,
        calmMode: Bool,
        dougHidden: Bool,
        launchAtLogin: LaunchAtLogin.State
    ) {
        let broken = !hasAccessibility || !hasScreenRecording
        let image = NSImage(
            systemSymbolName: broken ? "exclamationmark.triangle.fill" : "bubble.left.and.text.bubble.right",
            accessibilityDescription: broken ? "AI-slap needs attention" : "AI-slap"
        )
        image?.isTemplate = !broken
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = broken ? .systemRed : nil
        statusItem.button?.toolTip = broken ? "AI-slap permissions need attention — open the menu" : "AI-slap"

        if !hotkeyRegistered {
            handoffStatusItem.title = "⚠️ ⌥Space is taken by another app"
        } else if let last = lastHandoff() {
            handoffStatusItem.title = "Last handoff: \(last)"
        } else {
            handoffStatusItem.title = "Press ⌥Space on any window"
        }

        rebuildDestinations()
        reviewItem.state = HandoffRecovery.preference == .ask ? .on : .off
        nudgeItem.state = nudgesEnabled ? .on : .off
        nudgeStatusItem.title = nudgeStatus
        snoozeItem.isEnabled = nudgesEnabled
        mascotItem.state = mascotEnabled ? .on : .off
        calmItem.state = calmMode ? .on : .off
        hideDougItem.title = dougHidden ? "Hidden — ⌥⌘G to bring him back" : "Hide him now (⌥⌘G)"

        accessibilityItem.title = hasAccessibility
            ? "Accessibility on — handoffs can paste"
            : "⚠️ Accessibility off — click to fix"
        accessibilityItem.isEnabled = !hasAccessibility

        screenRecordingItem.title = hasScreenRecording
            ? "Screenshots on"
            : "⚠️ Screenshots off — click to set up"
        screenRecordingItem.isHidden = hasScreenRecording && hasAccessibility

        switch launchAtLogin {
        case .enabled:
            launchItem.title = "Open at login"
            launchItem.state = .on
            launchItem.isEnabled = true
        case .disabled:
            launchItem.title = "Open at login"
            launchItem.state = .off
            launchItem.isEnabled = true
        case .deniedBySystemSettings:
            launchItem.title = "Open at login — blocked in System Settings"
            launchItem.state = .off
            launchItem.isEnabled = false
        case .unavailable(let why):
            launchItem.title = "Open at login — unavailable (\(why))"
            launchItem.state = .off
            launchItem.isEnabled = false
        }
    }

    private func rebuildDestinations() {
        let submenu = NSMenu()
        let choices = destinations()
        if choices.isEmpty {
            let none = NSMenuItem(title: "No AI apps found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for choice in choices {
            let item = NSMenuItem(
                title: choice.installed ? choice.name : "\(choice.name) (in your browser)",
                action: #selector(setDestination(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.id
            item.state = choice.active ? .on : .off
            submenu.addItem(item)
        }
        destinationItem.submenu = submenu
    }

    @objc private func handoffNow() { onHandoffNow() }
    @objc private func toggleMascot() { onToggleMascot() }
    @objc private func toggleCalmMode() { onToggleCalmMode() }
    @objc private func toggleLaunchAtLogin() { onToggleLaunchAtLogin() }
    @objc private func fixPermission() { onFixPermission() }
    @objc private func showWelcome() { onShowWelcome() }
    @objc private func toggleNudges() { onToggleNudges() }
    @objc private func cancelSnooze() { onCancelSnooze() }

    @objc private func snooze(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        onSnooze(minutes)
    }

    @objc private func setDestination(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSetDestination(id)
    }

    /// Turning it back on is all-or-nothing on purpose: whichever "always" they landed
    /// on, the way out is the same tick, and there is no third state to explain.
    @objc private func toggleReview() {
        HandoffRecovery.preference = HandoffRecovery.preference == .ask ? .alwaysInclude : .ask
        reviewItem.state = HandoffRecovery.preference == .ask ? .on : .off
    }
}
