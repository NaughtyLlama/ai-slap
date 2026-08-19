import AppKit

/// The six steps of docs/05, in order: capture the window, build the prompt, stage the
/// pasteboard, open the destination, wait for it, paste — and never submit.
///
/// The clipboard is the universal fallback. Every failure path below leaves the payload
/// on it and says so, so the user is never stranded with a broken interaction and no
/// recourse.
final class Handoff {

    struct Target {
        let pid: pid_t
        let title: String?
        let prompt: String
    }

    enum Result {
        case pasted(hadImage: Bool)
        case clipboardOnly(reason: String)
        case needsScreenRecording
        case failed(String)

        var summary: String {
            switch self {
            case .pasted(let hadImage):
                return hadImage ? "pasted with screenshot" : "pasted, text only"
            case .clipboardOnly(let reason):
                return "clipboard only — \(reason)"
            case .needsScreenRecording:
                return "waiting on Screen Recording permission"
            case .failed(let message):
                return "failed — \(message)"
            }
        }
    }

    /// How long to wait for the destination to come forward. A cold launch is a
    /// different order of magnitude from activating an app that is already running,
    /// and docs/05's single "~2s" is only right for the warm case — the cold one was
    /// timing out every time and dropping the paste.
    private let warmTimeout: TimeInterval = 3
    private let coldTimeout: TimeInterval = 20

    /// A beat after the app is frontmost, so the composer has focus before the
    /// keystroke lands. A cold-started app needs noticeably longer to settle.
    private let warmSettle: TimeInterval = 0.35
    private let coldSettle: TimeInterval = 1.5

    private let destinations: [AIDestination]
    private var isRunning = false

    /// Set once we've asked for Screen Recording, so the ask happens exactly once.
    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "hasRequestedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "hasRequestedScreenRecording") }
    }

    private(set) var lastResult: Result?

    init(destinations: [AIDestination]) {
        self.destinations = destinations
    }

    var preferredDestination: AIDestination? {
        destinations.first { $0.isNativeAvailable } ?? destinations.first { $0.isAvailable }
    }

    func run(_ target: Target, completion: @escaping (Result) -> Void) {
        func finish(_ result: Result) {
            lastResult = result
            isRunning = false
            NSLog("AISlap: handoff — \(result.summary)")
            completion(result)
        }

        guard !isRunning else { return }
        isRunning = true

        guard let destination = preferredDestination else {
            finish(.failed("No AI destination is configured."))
            return
        }

        // Step 2, and the permission it needs. docs/02 defers Screen Recording out of
        // onboarding to here, the first handoff, where the ask explains itself.
        //
        // Asking is a blocking, focus-stealing system prompt, so it happens *before*
        // anything is staged and this run then stops. Running the rest of the flow
        // around a modal meant the destination never became frontmost and the paste
        // went nowhere. macOS also requires a relaunch before the grant takes effect.
        if !WindowCapture.hasPermission && !hasRequestedScreenRecording {
            hasRequestedScreenRecording = true
            _ = WindowCapture.requestPermission()
            finish(.needsScreenRecording)
            return
        }

        Task { @MainActor in
            let image = WindowCapture.hasPermission
                ? await WindowCapture.capture(pid: target.pid, title: target.title)
                : nil

            // Steps 3 and 4. The prompt is the rule's template verbatim: docs/05
            // forbids interpolating anything from the screen, and the window title in
            // particular is already reduced to a category token and discarded.
            let staged = Pasteboard.beginStaging()

            // Step 5.
            guard let opened = destination.open() else {
                Pasteboard.put(text: target.prompt)
                staged.keepPayload()
                finish(.clipboardOnly(reason: "couldn't open \(destination.name)"))
                return
            }

            let timeout = opened.wasAlreadyRunning ? self.warmTimeout : self.coldTimeout
            let settle = opened.wasAlreadyRunning ? self.warmSettle : self.coldSettle

            self.whenFrontmost(opened.bundleID, timeout: timeout, settle: settle) {
                arrived in
                guard arrived else {
                    Pasteboard.put(text: target.prompt)
                    staged.keepPayload()
                    finish(.clipboardOnly(
                        reason: "\(destination.name) didn't come forward in time"
                    ))
                    return
                }

                Task { @MainActor in
                    // A handoff belongs in a fresh conversation. Pasting into whatever
                    // thread was last open drops unrelated context into it, which is
                    // both confusing and a small privacy problem of its own.
                    if let shortcut = destination.newChatShortcut,
                       let (key, flags) = Keyboard.parse(shortcut) {
                        Keyboard.press(keyCode: key, flags: flags)
                        try? await Task.sleep(for: .milliseconds(600))
                    }

                    // Image and text are pasted separately. One combined write makes
                    // two pasteboard items and composers read only the first, which is
                    // exactly how the prompt arrived without its screenshot.
                    var pastedImage = false
                    if let image, destination.acceptsPastedImage {
                        Pasteboard.put(image: image)
                        pastedImage = Pasteboard.synthesizePaste()
                        try? await Task.sleep(for: .milliseconds(700))
                    }

                    Pasteboard.put(text: target.prompt)
                    guard Pasteboard.synthesizePaste() else {
                        staged.keepPayload()
                        finish(.clipboardOnly(reason: "paste didn't go through"))
                        return
                    }

                    // Step 6, the line that is never crossed: no Return. The user reads
                    // what is about to be sent and sends it themselves.
                    staged.restoreAfterPaste()
                    finish(.pasted(hadImage: pastedImage))
                }
            }
        }
    }

    private func whenFrontmost(
        _ bundleID: String,
        timeout: TimeInterval,
        settle: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.bundleIdentifier == bundleID, frontmost?.isFinishedLaunching == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                    completion(true)
                }
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: poll)
        }
        poll()
    }
}
