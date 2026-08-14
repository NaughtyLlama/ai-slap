import AppKit

/// The entire UI surface of Phase 0: a status item and a menu. No Dock icon, no
/// windows, no mascot. The mascot is Phase 1 and is gated on this spike's data.
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let permissionItem = NSMenuItem()
    private let contextItem = NSMenuItem()
    private let statsItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    private let onTogglePause: () -> Void
    private let onExport: () -> Void
    private let onRevealData: () -> Void
    private let onDeleteAll: () -> Void

    init(
        onTogglePause: @escaping () -> Void,
        onExport: @escaping () -> Void,
        onRevealData: @escaping () -> Void,
        onDeleteAll: @escaping () -> Void
    ) {
        self.onTogglePause = onTogglePause
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

        menu.addItem(withTitle: "AI-slap — Phase 0 logger", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(contextItem)
        menu.addItem(statsItem)
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
        let quit = NSMenuItem(
            title: "Quit AI-slap", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)
    }

    func update(
        context: WindowContext?,
        stats: SessionStore.Stats,
        isPaused: Bool,
        hasAccessibility: Bool
    ) {
        permissionItem.title = hasAccessibility
            ? "Accessibility granted — reading window titles"
            : "⚠️ No Accessibility permission — app names only"
        permissionItem.isHidden = false

        if isPaused {
            contextItem.title = "Paused — nothing is being logged"
        } else if let context {
            contextItem.title = "Now: \(context.appName) — \(truncated(context.displayTitle))"
        } else {
            contextItem.title = "Now: —"
        }

        let coverage = Int((stats.titleCoverage * 100).rounded())
        statsItem.title = String(
            format: "Today: %d sessions · %@ observed · %d%% with titles",
            stats.sessionCount,
            formatted(stats.totalDwell),
            coverage
        )

        pauseItem.title = isPaused ? "Resume logging" : "Pause logging"
        statusItem.button?.appearsDisabled = isPaused
    }

    private func truncated(_ title: String, limit: Int = 48) -> String {
        title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    @objc private func togglePause() { onTogglePause() }
    @objc private func export() { onExport() }
    @objc private func revealData() { onRevealData() }
    @objc private func deleteAll() { onDeleteAll() }
}
