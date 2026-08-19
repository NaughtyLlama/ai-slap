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

    /// Grabs the on-screen window belonging to `pid`, preferring an exact title match.
    /// Returns nil on any failure — docs/05 says a capture timeout aborts silently
    /// rather than throwing a modal at someone who is mid-task.
    static func capture(pid: pid_t, title: String?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid
            }
            guard !owned.isEmpty else { return nil }

            let target = owned.first { $0.title == title && title != nil }
                ?? owned.max { area($0) < area($1) }
            guard let window = target else { return nil }

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

    private static func area(_ window: SCWindow) -> CGFloat {
        window.frame.width * window.frame.height
    }

    private static var scaleFactor: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }
}
