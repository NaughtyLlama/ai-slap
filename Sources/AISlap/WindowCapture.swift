import AppKit
import ScreenCaptureKit

/// Captures a single window as an image, for the handoff flow only.
///
/// docs/05: capture the **window**, never the display. A full-screen grab sweeps in
/// whatever else is open — a privacy problem and a worse prompt.
///
/// docs/02 defers Screen Recording out of onboarding: detection never needs it, and it
/// is requested lazily here, on first handoff, where the ask explains itself. A denial
/// is not a failure — the handoff continues as text only.
enum WindowCapture {

    enum Availability {
        case granted
        case denied
    }

    /// Asks once. macOS shows its own prompt the first time; afterwards this is just a
    /// status read and the user has to change it in System Settings.
    static func requestPermission() -> Availability {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return CGRequestScreenCaptureAccess() ? .granted : .denied
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Which of the frontmost app's windows to photograph, or none.
    ///
    /// **One window is not a choice.** If the app owns a single on-screen window, that
    /// is the window the user is looking at, and there is nothing it could be confused
    /// with — so no title has to agree for it to be safe.
    ///
    /// Insisting on a title match even then looked rigorous and was useless: the title
    /// comes from the Accessibility API and the window list comes from ScreenCaptureKit,
    /// the two do not report the same string for the same window, and the result was a
    /// handoff that could never take a screenshot of a browser. Substituting an
    /// *unrelated* window is the thing worth refusing, and that can only arise when
    /// there is more than one to pick from.
    static func chooseIndex(titles: [String?], requested: String?) -> Int? {
        if titles.count == 1 { return 0 }
        guard let requested, !requested.isEmpty else { return nil }
        let matches = titles.indices.filter { titles[$0] == requested }
        return matches.count == 1 ? matches[0] : nil
    }

    static func capture(pid: pid_t, title: String?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid
            }
            guard let index = chooseIndex(titles: owned.map(\.title), requested: title)
            else { return nil }
            let window = owned[index]

            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scaleFactor)
            config.height = Int(window.frame.height * scaleFactor)
            config.showsCursor = false

            let filter = SCContentFilter(desktopIndependentWindow: window)
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            NSLog("AISlap: window capture failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static var scaleFactor: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}
