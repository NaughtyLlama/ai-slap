import AppKit
import ApplicationServices

/// Tier 0 + tier 1 detection, per docs/02-detection-architecture.md.
///
/// Tier 0: `NSWorkspace.frontmostApplication` → bundle ID. No permission.
/// Tier 1: Accessibility API → focused window title. One permission prompt.
///
/// Collection is event-driven. Two event sources are needed, not one:
///
///   - `NSWorkspace.didActivateApplicationNotification` fires when you switch apps.
///   - An `AXObserver` fires when the focused window changes *or* its title changes
///     without an app switch — which is exactly what happens when you switch browser
///     tabs or open a single Gmail message. That case is the highest-value signal in
///     the product, and the workspace notification alone never sees it.
///
/// A slow reconcile timer backstops both, because some Electron apps emit AX
/// notifications unreliably. It is deliberately slow — a 1 Hz poll on a resident app
/// is a battery complaint waiting to happen.
final class WindowContextObserver {

    /// Backstop interval for apps that do not emit AX notifications reliably.
    private static let reconcileInterval: TimeInterval = 10

    var onChange: ((WindowContext) -> Void)?

    private var current: WindowContext?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var observedAppElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var reconcileTimer: Timer?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        reconcileTimer = Timer.scheduledTimer(
            withTimeInterval: Self.reconcileInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refresh()
        }

        attachToFrontmostApp()
        refresh()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        detachAXObserver()
        current = nil
    }

    // MARK: - App switching

    @objc private func appActivated(_ notification: Notification) {
        attachToFrontmostApp()
        refresh()
    }

    private func attachToFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        guard pid != observedPID else { return }

        detachAXObserver()
        observedPID = pid

        // Without the Accessibility permission this returns an error and we stay on
        // tier 0 — bundle ID only. That degrades cleanly rather than failing.
        var observer: AXObserver?
        let result = AXObserverCreate(pid, axNotificationCallback, &observer)
        guard result == .success, let observer else { return }

        axObserver = observer
        let appElement = AXUIElementCreateApplication(pid)
        observedAppElement = appElement

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
        ] {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        subscribeToFocusedWindowTitle()
    }

    /// Title changes are emitted by the *window* element, not the app element, so the
    /// subscription has to move every time the focused window does.
    private func subscribeToFocusedWindowTitle() {
        guard let observer = axObserver, let appElement = observedAppElement else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        if let previous = observedWindowElement {
            AXObserverRemoveNotification(
                observer, previous, kAXTitleChangedNotification as CFString
            )
            observedWindowElement = nil
        }

        guard let window = copyFocusedWindow(of: appElement) else { return }
        observedWindowElement = window
        AXObserverAddNotification(
            observer, window, kAXTitleChangedNotification as CFString, refcon
        )
    }

    private func detachAXObserver() {
        if let observer = axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        axObserver = nil
        observedAppElement = nil
        observedWindowElement = nil
        observedPID = nil
    }

    // MARK: - Reading the current context

    fileprivate func handleAXNotification() {
        subscribeToFocusedWindowTitle()
        refresh()
    }

    func refresh() {
        guard isRunning else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        if app.processIdentifier != observedPID {
            attachToFrontmostApp()
        }

        let context = WindowContext(
            bundleID: app.bundleIdentifier ?? "unknown",
            appName: app.localizedName ?? "Unknown",
            title: focusedWindowTitle(pid: app.processIdentifier)
        )

        guard context != current else { return }
        current = context
        onChange?(context)
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        let appElement = observedAppElement ?? AXUIElementCreateApplication(pid)
        guard let window = copyFocusedWindow(of: appElement) else { return nil }

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &value
        )
        guard result == .success, let title = value as? String, !title.isEmpty else {
            return nil
        }
        return title
    }

    private func copyFocusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &value
        )
        guard result == .success, let window = value else { return nil }
        // CFTypeRef → AXUIElement is only valid if the returned type actually is one.
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }
}

/// AXObserver callbacks are C function pointers, so `self` travels in the refcon.
private func axNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let target = Unmanaged<WindowContextObserver>.fromOpaque(refcon)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        target.handleAXNotification()
    }
}
