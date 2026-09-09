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

    let destinations: [AIDestination]
    private var isRunning = false

    /// Which destination the user picked, by rulebook id.
    ///
    /// The first build had no such thing: it took the first natively installed entry,
    /// which made "hand off to Claude" a property of the list order rather than a choice.
    /// That is fine right up until someone works in ChatGPT or Gemini, at which point
    /// the product silently hands their window to an app they don't use.
    static var preferredID: String? {
        get { UserDefaults.standard.string(forKey: "destination") }
        set { UserDefaults.standard.set(newValue, forKey: "destination") }
    }

    /// Set once the user has been asked, so first run asks and no later run nags.
    static var hasChosenDestination: Bool {
        get { UserDefaults.standard.bool(forKey: "hasChosenDestination") }
        set { UserDefaults.standard.set(newValue, forKey: "hasChosenDestination") }
    }

    /// Set once we've asked for Screen Recording, so the ask happens exactly once.
    private var hasRequestedScreenRecording: Bool {
        get { UserDefaults.standard.bool(forKey: "hasRequestedScreenRecording") }
        set { UserDefaults.standard.set(newValue, forKey: "hasRequestedScreenRecording") }
    }

    private(set) var lastResult: Result?

    init(destinations: [AIDestination]) {
        self.destinations = destinations
    }

    /// The user's choice if it is usable, and otherwise the old behaviour — because a
    /// chosen destination whose app has since been uninstalled should degrade to
    /// *something working*, not to a failed handoff and a lost capture.
    var preferredDestination: AIDestination? {
        if let id = Self.preferredID,
           let chosen = destinations.first(where: { $0.id == id }),
           chosen.isAvailable
        {
            return chosen
        }
        return destinations.first { $0.isNativeAvailable } ?? destinations.first { $0.isAvailable }
    }

    /// Everything the user could pick, installed or reachable on the web.
    var availableDestinations: [AIDestination] { destinations.filter(\.isAvailable) }

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
                    // Native only. On the web fallback the frontmost app is a browser,
                    // where ⌘N opens a new *window* — so the handoff would paste into a
                    // blank tab that never navigated anywhere.
                    if opened.isNative,
                       let shortcut = destination.newChatShortcut,
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
