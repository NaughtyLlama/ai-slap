import AppKit

/// The whole UI. Still no windows and no Dock icon — the mascot (docs/04) replaces
/// the notification delivery in Phase 1, not this menu.
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let permissionItem = NSMenuItem()
    private let notificationItem = NSMenuItem()
    private let contextItem = NSMenuItem()
    private let statusItemLine = NSMenuItem()
    private let statsItem = NSMenuItem()
    private let nudgeStatsItem = NSMenuItem()
    private let nudgeToggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private var sensitivityItems: [InterruptionEngine.Sensitivity: NSMenuItem] = [:]

    private let onTogglePause: () -> Void
    private let onToggleNudges: () -> Void
    private let onSetSensitivity: (InterruptionEngine.Sensitivity) -> Void
    private let onShowLearned: () -> Void
    private let onTestNudge: () -> Void
    private let onHandoffNow: () -> Void
    private let onFixPermission: () -> Void
    private let onExport: () -> Void
    private let onRevealData: () -> Void
    private let onDeleteAll: () -> Void

    init(
        onTogglePause: @escaping () -> Void,
        onToggleNudges: @escaping () -> Void,
        onSetSensitivity: @escaping (InterruptionEngine.Sensitivity) -> Void,
        onShowLearned: @escaping () -> Void,
        onTestNudge: @escaping () -> Void,
        onHandoffNow: @escaping () -> Void,
        onFixPermission: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onRevealData: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onToggleNudges = onToggleNudges
        self.onSetSensitivity = onSetSensitivity
        self.onShowLearned = onShowLearned
        self.onTestNudge = onTestNudge
        self.onHandoffNow = onHandoffNow
        self.onFixPermission = onFixPermission
        self.onExport = onExport
        self.onRevealData = onRevealData
        self.onDeleteAll = onDeleteAll

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        statusItem.menu = menu
    }

    /// The icon is the only part of this app most people will ever look at, so a
    /// missing permission has to be visible there. Losing an afternoon to a warning
    /// buried one click deep in a menu is how the last one went.
    private func applyIcon(hasAccessibility: Bool, notificationsAllowed: Bool) {
        let broken = !hasAccessibility || !notificationsAllowed
        let symbol = broken ? "exclamationmark.triangle.fill" : "eye"
        let image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: broken ? "AI-slap needs attention" : "AI-slap"
        )
        image?.isTemplate = !broken
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = broken ? .systemRed : nil
        statusItem.button?.toolTip = broken
            ? "AI-slap can't work — open the menu"
            : "AI-slap"
    }

    private func buildMenu() {
        contextItem.isEnabled = false
        statusItemLine.isEnabled = false
        statsItem.isEnabled = false
        nudgeStatsItem.isEnabled = false

        menu.addItem(withTitle: "AI-slap", action: nil, keyEquivalent: "").isEnabled = false

        // Clickable, because when this is the problem it's the only thing that matters.
        permissionItem.target = self
        permissionItem.action = #selector(fixPermission)
        menu.addItem(permissionItem)
        menu.addItem(notificationItem)

        menu.addItem(.separator())
        menu.addItem(contextItem)
        menu.addItem(statusItemLine)
        menu.addItem(statsItem)
        menu.addItem(nudgeStatsItem)
        menu.addItem(.separator())

        nudgeToggleItem.target = self
        nudgeToggleItem.action = #selector(toggleNudges)
        menu.addItem(nudgeToggleItem)

        let sensitivityMenu = NSMenu()
        for sensitivity in InterruptionEngine.Sensitivity.allCases {
            let item = NSMenuItem(
                title: sensitivity.title,
                action: #selector(setSensitivity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = sensitivity.rawValue
            sensitivityMenu.addItem(item)
            sensitivityItems[sensitivity] = item
        }
        let sensitivityRoot = NSMenuItem(
            title: "How pushy?", action: nil, keyEquivalent: ""
        )
        sensitivityRoot.submenu = sensitivityMenu
        menu.addItem(sensitivityRoot)

        let learned = NSMenuItem(
            title: "What it's learned about you…",
            action: #selector(showLearned), keyEquivalent: ""
        )
        learned.target = self
        menu.addItem(learned)

        let test = NSMenuItem(
            title: "Send a test nudge", action: #selector(testNudge), keyEquivalent: ""
        )
        test.target = self
        menu.addItem(test)

        menu.addItem(.separator())

        // The hotkey is the real entry point; this exists so the feature is
        // discoverable and so the shortcut is written down somewhere.
        let handoff = NSMenuItem(
            title: "Hand this window to Claude", action: #selector(handoffNow),
            keyEquivalent: " "
        )
        handoff.keyEquivalentModifierMask = [.option]
        handoff.target = self
        menu.addItem(handoff)

        menu.addItem(.separator())

        pauseItem.target = self
        pauseItem.action = #selector(togglePause)
        menu.addItem(pauseItem)

        let export = NSMenuItem(
            title: "Export CSV for labelling…", action: #selector(export), keyEquivalent: ""
        )
        export.target = self
        menu.addItem(export)

        let reveal = NSMenuItem(
            title: "Show data folder", action: #selector(revealData), keyEquivalent: ""
        )
        reveal.target = self
        menu.addItem(reveal)

        let delete = NSMenuItem(
            title: "Delete all data…", action: #selector(deleteAll), keyEquivalent: ""
        )
        delete.target = self
        menu.addItem(delete)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit AI-slap", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    func update(
        context: WindowContext?,
        category: String?,
        statusLine: String,
        stats: SessionStore.Stats,
        nudgesToday: Int,
        dailyBudget: Int,
        isPaused: Bool,
        nudgesEnabled: Bool,
        sensitivity: InterruptionEngine.Sensitivity,
        hasAccessibility: Bool,
        notificationsAllowed: Bool
    ) {
        applyIcon(
            hasAccessibility: hasAccessibility,
            notificationsAllowed: notificationsAllowed
        )

        permissionItem.title = hasAccessibility
            ? "Accessibility granted — reading window titles"
            : "⚠️ No Accessibility permission — click to fix"
        permissionItem.isEnabled = !hasAccessibility

        notificationItem.title = notificationsAllowed
            ? "Notifications allowed"
            : "⚠️ Notifications blocked — nudges can't appear"
        notificationItem.isEnabled = false
        notificationItem.isHidden = notificationsAllowed && hasAccessibility

        statusItemLine.title = isPaused ? "Paused" : statusLine

        if isPaused {
            contextItem.title = "Paused — nothing is being logged"
        } else if let context {
            let suffix = category.map { " · \($0)" } ?? ""
            contextItem.title =
                "Now: \(context.appName) — \(truncated(context.displayTitle))\(suffix)"
        } else {
            contextItem.title = "Now: —"
        }

        let coverage = Int((stats.titleCoverage * 100).rounded())
        statsItem.title = String(
            format: "Today: %d sessions · %@ observed · %d%% with titles",
            stats.sessionCount, formatted(stats.totalDwell), coverage
        )
        nudgeStatsItem.title = "Nudges today: \(nudgesToday) of \(dailyBudget)"

        nudgeToggleItem.title = nudgesEnabled ? "Nudges: on" : "Nudges: off"
        nudgeToggleItem.state = nudgesEnabled ? .on : .off

        for (key, item) in sensitivityItems {
            item.state = key == sensitivity ? .on : .off
        }

        pauseItem.title = isPaused ? "Resume logging" : "Pause logging"
        statusItem.button?.appearsDisabled = isPaused
    }

    private func truncated(_ title: String, limit: Int = 44) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    @objc private func togglePause() { onTogglePause() }
    @objc private func toggleNudges() { onToggleNudges() }
    @objc private func showLearned() { onShowLearned() }
    @objc private func testNudge() { onTestNudge() }
    @objc private func handoffNow() { onHandoffNow() }
    @objc private func fixPermission() { onFixPermission() }
    @objc private func export() { onExport() }
    @objc private func revealData() { onRevealData() }
    @objc private func deleteAll() { onDeleteAll() }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sensitivity = InterruptionEngine.Sensitivity(rawValue: raw)
        else { return }
        onSetSensitivity(sensitivity)
    }
}
