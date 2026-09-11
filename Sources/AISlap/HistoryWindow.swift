import AppKit
import SQLite3

final class HistoryWindow {
    private var window: NSWindow?

    func show(text: String) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "AI-slap usage history"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false
            view.isSelectable = true
            view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            view.textContainerInset = NSSize(width: 16, height: 16)
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view
            window.contentView = scroll
            window.center()
            self.window = window
        }
        if let scroll = window?.contentView as? NSScrollView,
           let view = scroll.documentView as? NSTextView { view.string = text }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

extension SessionStore {
    /// Monthly category totals and all-time app totals contain no window titles.
    func historySummary() -> String {
        let retention = retentionDays == 0 ? "Until you delete it" : "\(retentionDays) days"
        var text = "Usage history\nKept: \(retention)\n\n"
        text += "Window titles and screenshots are not saved.\n"
        text += "These are observed window durations, not a measure of productive work.\n"
        text += "The current open session appears after you switch context.\n\n"
        func rows(sql: String) -> [(String, String, Double)] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var result: [(String, String, Double)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let a = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let b = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                result.append((a, b, sqlite3_column_double(statement, 2)))
            }
            return result
        }
        let months = rows(sql: """
            SELECT strftime('%Y-%m', started_at, 'unixepoch', 'localtime'),
                   COALESCE(category, 'unclassified'), SUM(dwell_seconds)
            FROM sessions GROUP BY 1, 2 ORDER BY 1 DESC, 3 DESC;
            """)
        if months.isEmpty { return text + "No completed sessions yet." }
        text += "MONTH / CATEGORY / OBSERVED HOURS\n"
        for (month, category, seconds) in months {
            text += String(format: "%@  %@  %.2f h\n", month, category, seconds / 3600)
        }
        text += "\nAPP TOTALS / OBSERVED HOURS\n"
        for (name, _, seconds) in rows(sql: """
            SELECT app_name, bundle_id, SUM(dwell_seconds)
            FROM sessions GROUP BY bundle_id ORDER BY 3 DESC;
            """) {
            text += String(format: "%@  %.2f h\n", name, seconds / 3600)
        }
        text += "\nUse Export usage history for individual session dates and durations.\n"
        return text
    }
}
