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
        let pid: pid_t
        let bundleID: String
        let wasAlreadyRunning: Bool
        let isWeb: Bool
    }

    /// Opening completion supplies the actual destination process, including the
    /// user's default URL handler. Web routes never use native keyboard shortcuts.
    @MainActor
    func open() async -> Opened? {
        let workspace = NSWorkspace.shared
        let nativeURL = bundleId.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let pageURL = webURL.flatMap(URL.init(string:))
        guard let appURL = nativeURL ?? pageURL.flatMap({ workspace.urlForApplication(toOpen: $0) }),
              let actualBundleID = Bundle(url: appURL)?.bundleIdentifier else { return nil }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: actualBundleID).isEmpty
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            let app: NSRunningApplication
            if nativeURL != nil {
                app = try await workspace.openApplication(at: appURL, configuration: configuration)
            } else if let pageURL {
                app = try await workspace.open([pageURL], withApplicationAt: appURL, configuration: configuration)
            } else { return nil }
            return Opened(pid: app.processIdentifier, bundleID: actualBundleID,
                          wasAlreadyRunning: running, isWeb: nativeURL == nil)
        } catch { return nil }
    }
}
