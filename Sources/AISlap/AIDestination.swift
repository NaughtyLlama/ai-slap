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

    var isNativeAvailable: Bool {
        guard let bundleId else { return false }
        return NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    var isAvailable: Bool { isNativeAvailable || webURL != nil }

    /// Opens the destination and reports the bundle ID to wait for before pasting.
    @discardableResult
    func open() -> String? {
        if let bundleId,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return bundleId
        }

        // docs/05: destination app not installed → fall back to the web adapter.
        guard let webURL, let url = URL(string: webURL) else { return nil }
        NSWorkspace.shared.open(url)
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
