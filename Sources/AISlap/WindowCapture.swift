import AppKit
import ApplicationServices
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

    /// One candidate window, reduced to the two things that can identify it.
    struct Candidate: Equatable {
        let title: String?
        let frame: CGRect
    }

    /// How a window was identified, for the log. Which strategy actually earns its
    /// keep is a question about other people's machines, not a matter of opinion.
    enum Match: String { case onlyWindow = "only window", title = "title", position = "position" }

    /// Which of the frontmost app's windows to photograph, or none.
    ///
    /// Three tests, narrowest first, and the point of having three is that each one
    /// fails on a different kind of app:
    ///
    /// 1. **One window is not a choice.** A single on-screen window is the one the user
    ///    is looking at and there is nothing it could be confused with.
    /// 2. **A unique title match.** Works whenever the two APIs agree on the string —
    ///    and they do for some apps, which is why this is kept rather than replaced.
    /// 3. **The same rectangle.** The title comes from the Accessibility API and the
    ///    window list from ScreenCaptureKit, and those **do not report the same string
    ///    for the same window** in every app — a browser handoff could never take a
    ///    screenshot while this was the only test. Both report a frame, and a window is
    ///    in exactly one place.
    ///
    /// If none of the three resolves, no screenshot is taken. Substituting an unrelated
    /// window is the thing worth refusing, and with several windows open and no test
    /// agreeing, that is exactly what a guess would risk.
    static func choose(_ windows: [Candidate], title: String?, focused: CGRect?) -> (index: Int, how: Match)? {
        if windows.count == 1 { return (0, .onlyWindow) }
        if let title, !title.isEmpty {
            let matches = windows.indices.filter { windows[$0].title == title }
            if matches.count == 1 { return (matches[0], .title) }
        }
        if let focused, !focused.isEmpty {
            let matches = windows.indices.filter { overlap(windows[$0].frame, focused) >= 0.9 }
            if matches.count == 1 { return (matches[0], .position) }
        }
        return nil
    }

    /// Intersection over union. A tolerance rather than equality because the two APIs
    /// round to points differently, and a shadow or a titlebar inset should not lose a
    /// window that is plainly the same one.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let hit = a.intersection(b)
        guard !hit.isNull, !hit.isEmpty else { return 0 }
        let union = a.width * a.height + b.width * b.height - hit.width * hit.height
        guard union > 0 else { return 0 }
        return (hit.width * hit.height) / union
    }

    /// Where the app says its focused window is. Needs Accessibility, which the app
    /// already holds for detection, and costs nothing when it is missing.
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }
        let window = windowRef as! AXUIElement

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    static func capture(pid: pid_t, title: String?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            let owned = content.windows.filter {
                $0.owningApplication?.processID == pid
            }
            let candidates = owned.map { Candidate(title: $0.title, frame: $0.frame) }
            guard let (index, how) = choose(
                candidates, title: title, focused: focusedWindowFrame(pid: pid)
            ) else {
                NSLog("AISlap: capture — no window identified among \(owned.count) for pid \(pid)")
                return nil
            }
            NSLog("AISlap: capture — window identified by \(how.rawValue)")
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
