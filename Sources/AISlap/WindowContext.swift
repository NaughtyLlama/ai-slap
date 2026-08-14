import Foundation

/// One observed foreground context: which app is frontmost and what its focused
/// window is called.
struct WindowContext: Equatable {
    let bundleID: String
    let appName: String
    let title: String?

    var displayTitle: String { title ?? "—" }
}

/// A context that has ended, ready to be written to the log.
struct Session {
    let context: WindowContext
    let startedAt: Date
    let endedAt: Date

    var dwell: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
