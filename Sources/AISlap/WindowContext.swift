import Foundation

/// One observed foreground context: which app is frontmost and what its focused
/// window is called.
struct WindowContext: Equatable {
    let bundleID: String
    let appName: String
    let title: String?

    var displayTitle: String { title ?? "—" }

    /// The leading segment of the title, which is what identifies a *surface*:
    /// "Termly - Part of group…" and "Termly - Google Chrome" are the same tool.
    /// Used by the accumulation rule to total a day's time in one place.
    var surfaceKey: String? {
        guard let title else { return nil }
        let head = title.components(separatedBy: " - ").first ?? title
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3 ? trimmed : nil
    }
}

/// A context that has ended, ready to be written to the log.
struct Session {
    let context: WindowContext
    let startedAt: Date
    let endedAt: Date

    var dwell: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
