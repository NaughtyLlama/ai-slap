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
    private let handoffStatusItem = NSMenuItem()
    private let nudgeToggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private var sensitivityItems: [InterruptionEngine.Sensitivity: NSMenuItem] = [:]
    private var amnestyItems: [InterruptionEngine.Amnesty: NSMenuItem] = [:]
    private var budgetItems: [Int: NSMenuItem] = [:]
    private var styleItems: [InterruptionEngine.Style: NSMenuItem] = [:]
    private let panicItem = NSMenuItem()

    private let onTogglePause: () -> Void
    private let onToggleNudges: () -> Void
    private let onSetSensitivity: (InterruptionEngine.Sensitivity) -> Void
    private let onSetAmnesty: (InterruptionEngine.Amnesty) -> Void
    private let onSetBudget: (Int) -> Void
    private let onShowLearned: () -> Void
    private let onTestNudge: () -> Void
    private let onSetStyle: (InterruptionEngine.Style) -> Void
    private let onTogglePanic: () -> Void
    private let onHandoffNow: () -> Void
    private let onFixPermission: () -> Void
    private let onExport: () -> Void
    private let onRevealData: () -> Void
    private let onDeleteAll: () -> Void

    init(
        onTogglePause: @escaping () -> Void,
        onToggleNudges: @escaping () -> Void,
        onSetSensitivity: @escaping (InterruptionEngine.Sensitivity) -> Void,
        onSetAmnesty: @escaping (InterruptionEngine.Amnesty) -> Void,
        onSetBudget: @escaping (Int) -> Void,
        onShowLearned: @escaping () -> Void,
        onTestNudge: @escaping () -> Void,
        onSetStyle: @escaping (InterruptionEngine.Style) -> Void,
        onTogglePanic: @escaping () -> Void,
        onHandoffNow: @escaping () -> Void,
        onFixPermission: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onRevealData: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onToggleNudges = onToggleNudges
        self.onSetSensitivity = onSetSensitivity
        self.onSetAmnesty = onSetAmnesty
        self.onSetBudget = onSetBudget
        self.onShowLearned = onShowLearned
        self.onTestNudge = onTestNudge
        self.onSetStyle = onSetStyle
        self.onTogglePanic = onTogglePanic
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

        let styleMenu = NSMenu()
        for style in InterruptionEngine.Style.allCases {
            let item = NSMenuItem(
                title: style.title, action: #selector(setStyle(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            styleMenu.addItem(item)
            styleItems[style] = item
        }
        let styleRoot = NSMenuItem(title: "Show nudges as", action: nil, keyEquivalent: "")
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)

        let amnestyMenu = NSMenu()
        for amnesty in InterruptionEngine.Amnesty.allCases {
            let item = NSMenuItem(
                title: amnesty.title, action: #selector(setAmnesty(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = amnesty.rawValue
            amnestyMenu.addItem(item)
            amnestyItems[amnesty] = item
        }
        let amnestyRoot = NSMenuItem(
            title: "Pause after I use AI", action: nil, keyEquivalent: ""
        )
        amnestyRoot.submenu = amnestyMenu
        menu.addItem(amnestyRoot)

        let budgetMenu = NSMenu()
        for budget in [4, 8, 15, 40] {
            let item = NSMenuItem(
                title: "\(budget) a day", action: #selector(setBudget(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = budget
            budgetMenu.addItem(item)
            budgetItems[budget] = item
        }
        let budgetRoot = NSMenuItem(title: "How many, max?", action: nil, keyEquivalent: "")
        budgetRoot.submenu = budgetMenu
        menu.addItem(budgetRoot)

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
        // The shortcut is owned by the Carbon hotkey, which works globally. Setting it
        // as a menu key equivalent as well would give the combination two owners.
        let handoff = NSMenuItem(
            title: "Hand this window to Claude  (\u{2325}Space)",
            action: #selector(handoffNow), keyEquivalent: ""
        )
        handoff.target = self
        menu.addItem(handoff)
        handoffStatusItem.isEnabled = false
        menu.addItem(handoffStatusItem)

        menu.addItem(.separator())

        // docs/04 ships this as a hotkey and a menu item, both instant.
        panicItem.target = self
        panicItem.action = #selector(togglePanic)
        menu.addItem(panicItem)

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
        amnesty: InterruptionEngine.Amnesty,
        style: InterruptionEngine.Style,
        isPanicked: Bool,
        budget: Int,
        hasAccessibility: Bool,
        notificationsAllowed: Bool,
        hotkeyRegistered: Bool,
        hotkeyPresses: Int,
        lastHandoff: String?
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

        // "Did the shortcut even fire?" has to be answerable without reading a log.
        if !hotkeyRegistered {
            handoffStatusItem.title = "⚠️ ⌥Space is taken by another app"
        } else if let lastHandoff {
            handoffStatusItem.title = "Last handoff: \(lastHandoff)"
        } else {
            handoffStatusItem.title = hotkeyPresses == 0
                ? "Shortcut ready — not used yet"
                : "Shortcut pressed \(hotkeyPresses)× — no handoff completed"
        }

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
        for (key, item) in styleItems {
            item.state = key == style ? .on : .off
        }
        panicItem.title = isPanicked
            ? "Hidden — click to resume"
            : "Hide for 30 minutes  (\u{2325}\u{2318}G)"
        for (key, item) in amnestyItems {
            item.state = key == amnesty ? .on : .off
        }
        for (key, item) in budgetItems {
            item.state = key == budget ? .on : .off
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

    @objc private func togglePanic() { onTogglePanic() }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = InterruptionEngine.Style(rawValue: raw)
        else { return }
        onSetStyle(style)
    }

    @objc private func setAmnesty(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let amnesty = InterruptionEngine.Amnesty(rawValue: raw)
        else { return }
        onSetAmnesty(amnesty)
    }

    @objc private func setBudget(_ sender: NSMenuItem) {
        guard let budget = sender.representedObject as? Int else { return }
        onSetBudget(budget)
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let sensitivity = InterruptionEngine.Sensitivity(rawValue: raw)
        else { return }
        onSetSensitivity(sensitivity)
    }
}
