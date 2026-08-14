import AppKit

/// The whole UI. Still no windows and no Dock icon — the mascot (docs/04) replaces
/// the notification delivery in Phase 1, not this menu.
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let permissionItem = NSMenuItem()
    private let contextItem = NSMenuItem()
    private let statsItem = NSMenuItem()
    private let nudgeStatsItem = NSMenuItem()
    private let nudgeToggleItem = NSMenuItem()
    private let pauseItem = NSMenuItem()
    private var sensitivityItems: [InterruptionEngine.Sensitivity: NSMenuItem] = [:]

    private let onTogglePause: () -> Void
    private let onToggleNudges: () -> Void
    private let onSetSensitivity: (InterruptionEngine.Sensitivity) -> Void
    private let onShowLearned: () -> Void
    private let onExport: () -> Void
    private let onRevealData: () -> Void
    private let onDeleteAll: () -> Void

    init(
        onTogglePause: @escaping () -> Void,
        onToggleNudges: @escaping () -> Void,
        onSetSensitivity: @escaping (InterruptionEngine.Sensitivity) -> Void,
        onShowLearned: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onRevealData: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
        self.onToggleNudges = onToggleNudges
        self.onSetSensitivity = onSetSensitivity
        self.onShowLearned = onShowLearned
        self.onExport = onExport
        self.onRevealData = onRevealData
        self.onDeleteAll = onDeleteAll

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "eye", accessibilityDescription: "AI-slap"
        )
        statusItem.button?.image?.isTemplate = true

        buildMenu()
        statusItem.menu = menu
    }

    private func buildMenu() {
        permissionItem.isEnabled = false
        contextItem.isEnabled = false
        statsItem.isEnabled = false
        nudgeStatsItem.isEnabled = false

        menu.addItem(withTitle: "AI-slap", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(contextItem)
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
        stats: SessionStore.Stats,
        nudgesToday: Int,
        dailyBudget: Int,
        isPaused: Bool,
        nudgesEnabled: Bool,
        sensitivity: InterruptionEngine.Sensitivity,
        hasAccessibility: Bool
    ) {
        permissionItem.title = hasAccessibility
            ? "Accessibility granted — reading window titles"
            : "⚠️ No Accessibility permission — app names only"

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
