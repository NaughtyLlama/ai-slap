import AppKit

/// Where a handoff goes. docs/05 keeps the per-target details in the rulebook rather
/// than compiled in, so a vendor changing something is a rulebook push rather than an
/// app release plus a notarisation round.
struct AIDestination: Decodable {
    let id: String
    let name: String
    /// Native client, preferred when installed — faster, already authenticated, and it
    /// handles pasted images reliably.
    let bundleId: String?
    /// Web fallback. Deliberately carries **no prompt-prefill parameters**: docs/05
    /// warns those formats have changed more than once and refuses to assert one, and
    /// prefill is text-only anyway. The pasteboard carries both text and image, so the
    /// flow does not depend on a URL contract that might silently rot.
    let webURL: String?
    /// Keystroke that starts a fresh conversation, sent once the destination is
    /// frontmost. Lives here rather than in code because it is exactly the kind of
    /// per-vendor detail docs/05 wants updatable without an app release.
    let newChatShortcut: String?
    /// Terminals and editors can't take a pasted image; they need a file path instead.
    let acceptsPastedImage: Bool

    var isNativeAvailable: Bool {
        guard let bundleId else { return false }
        return NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    var isAvailable: Bool { isNativeAvailable || webURL != nil }

    struct Opened {
        let bundleID: String
        /// Whether the app was already running. A cold launch needs far longer to
        /// reach a state where a keystroke means anything, and guessing one timeout
        /// for both cases is how the paste got dropped.
        let wasAlreadyRunning: Bool
        /// False when this fell back to the web adapter — in which case the frontmost
        /// app is a browser and the new-chat shortcut means something else entirely.
        let isNative: Bool
    }

    /// Opens the destination and reports what to wait for before pasting.
    func open() -> Opened? {
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            let wasRunning = !NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).isEmpty

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return Opened(
                bundleID: bundleId, wasAlreadyRunning: wasRunning, isNative: true
            )
        }

        // docs/05: destination app not installed → fall back to the web adapter.
        guard let webURL, let url = URL(string: webURL) else { return nil }
        let browserBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        NSWorkspace.shared.open(url)
        guard let browserBefore else { return nil }
        return Opened(
            bundleID: browserBefore, wasAlreadyRunning: true, isNative: false
        )
    }
}
