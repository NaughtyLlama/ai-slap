import AppKit

/// When the interruption must not appear at all.
///
/// docs/04 is blunt about why this gets its own section: a mascot appearing during a
/// board demo is the anecdote that kills the company. The asymmetry drives the design —
/// **hiding when you didn't need to costs nothing; failing to hide once costs the
/// account** — so every check here errs toward hiding.
final class Suppression {

    private let conferencingBundleIDs: Set<String>
    private var panicUntil: Date?
    private var screenIsLocked = false

    /// docs/04: the panic hotkey hides everything for half an hour. Users need to trust
    /// they can make it vanish in one keystroke or they won't run it at all.
    static let panicDuration: TimeInterval = 30 * 60

    init(conferencingBundleIDs: [String]) {
        self.conferencingBundleIDs = Set(conferencingBundleIDs)
        observeScreenLock()
    }

    struct Verdict {
        let suppressed: Bool
        let reason: String?
    }

    func check() -> Verdict {
        if let panicUntil, Date() < panicUntil {
            let minutes = Int(panicUntil.timeIntervalSinceNow / 60) + 1
            return Verdict(suppressed: true, reason: "hidden for another \(minutes)m")
        }
        if screenIsLocked {
            return Verdict(suppressed: true, reason: "screen locked")
        }
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier,
           conferencingBundleIDs.contains(bundleID)
        {
            return Verdict(
                suppressed: true,
                reason: "\(app.localizedName ?? "a call app") is in front"
            )
        }
        return Verdict(suppressed: false, reason: nil)
    }

    func panic() {
        panicUntil = Date().addingTimeInterval(Self.panicDuration)
    }

    func cancelPanic() {
        panicUntil = nil
    }

    var isPanicked: Bool {
        guard let panicUntil else { return false }
        return Date() < panicUntil
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.screenIsLocked = true }
        center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.screenIsLocked = false }
    }
}
