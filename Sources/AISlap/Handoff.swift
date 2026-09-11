import AppKit
import ApplicationServices

/// Capture → local review → open → guarded native paste (or explicit web paste).
/// Every uncertain delivery retains a short-lived, in-memory recovery payload.
final class Handoff {
    struct Target {
        let pid: pid_t
        let title: String?
        let prompt: String
        let createdAt = Date()
    }

    enum Result {
        case pasteRequested(hadImage: Bool)
        case clipboardOnly(reason: String)
        case needsScreenRecording
        case cancelled
        case failed(String)

        var summary: String {
            switch self {
            case .pasteRequested(let image): return image ? "paste requested with screenshot" : "paste requested, text only"
            case .clipboardOnly(let reason): return "manual paste — \(reason)"
            case .needsScreenRecording: return "Screen Recording settings opened — try again afterward"
            case .cancelled: return "cancelled"
            case .failed(let message): return "failed — \(message)"
            }
        }
    }

    enum ReviewChoice { case includeImage, textOnly, cancel, permission }

    /// All external effects are injected so focus, clipboard and cancellation races
    /// can be tested without capturing the user's screen or sending any keystrokes.
    struct Environment {
        var hasScreenPermission: @MainActor () -> Bool = { WindowCapture.hasPermission }
        var capture: @MainActor (Target) async -> CGImage? = { await WindowCapture.capture(pid: $0.pid, title: $0.title) }
        var review: @MainActor (CGImage?, Bool) -> ReviewChoice = { HandoffRecovery.review(image: $0, hasPermission: $1) }
        var requestPermission: @MainActor () -> Void = {
            _ = WindowCapture.requestPermission()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        var open: @MainActor (AIDestination) async -> AIDestination.Opened? = { await $0.open() }
        var frontmostPID: @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        var isTrusted: @MainActor () -> Bool = { AXIsProcessTrusted() }
        var editable: @MainActor (pid_t) -> Bool = { Keyboard.hasEditableFocus(pid: $0) }
        var press: @MainActor (CGKeyCode, CGEventFlags, pid_t) -> Bool = { Keyboard.press(keyCode: $0, flags: $1, pid: $2) }
        var stage: @MainActor () -> Pasteboard.Staged = { Pasteboard.beginStaging() }
        var recover: @MainActor (String, CGImage?, String) -> Void = { HandoffRecovery.shared.show(prompt: $0, image: $1, message: $2) }
        var clearRecovery: @MainActor () -> Void = { HandoffRecovery.shared.close() }
        var sleep: @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    let destinations: [AIDestination]
    private let environment: Environment
    private var activeID: UUID?
    private var task: Task<Void, Never>?
    private var activeClipboard: Pasteboard.Staged?
    private(set) var lastResult: Result?

    init(destinations: [AIDestination], environment: Environment = Environment()) {
        self.destinations = destinations
        self.environment = environment
    }

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

    /// Used by erase/pause: no delayed callback may resurrect a cleared payload.
    func cancel() {
        activeID = nil
        task?.cancel()
        task = nil
        lastResult = nil
        activeClipboard?.restoreIfOwned()
        activeClipboard = nil
        Task { @MainActor in environment.clearRecovery() }
    }

    func run(_ target: Target, completion: @escaping (Result) -> Void) {
        guard activeID == nil else { return }
        let id = UUID()
        activeID = id
        task = Task { @MainActor in
            let env = environment
            @MainActor func current() -> Bool { activeID == id && !Task.isCancelled }
            @MainActor func finish(_ result: Result) {
                guard current() else { return }
                lastResult = result
                activeID = nil
                task = nil
                activeClipboard = nil
                NSLog("AISlap: handoff — \(result.summary)")
                completion(result)
            }
            guard let destination = preferredDestination else {
                finish(.failed("No AI destination is configured.")); return
            }
            env.clearRecovery()
            let granted = env.hasScreenPermission()
            let captured = granted ? await env.capture(target) : nil
            guard current() else { return }
            let choice = env.review(captured, granted)
            guard current() else { return }
            switch choice {
            case .cancel: finish(.cancelled); return
            case .permission:
                env.requestPermission()
                finish(.needsScreenRecording); return
            default: break
            }
            let image = choice == .includeImage ? captured : nil
            // Snapshot before opening: a user copy during a cold launch must win.
            let staged = env.stage()
            activeClipboard = staged
            @MainActor func manual(_ reason: String) {
                guard current() else { return }
                let copied = staged.put(text: target.prompt)
                let message = copied ? "Prompt copied. Click the AI composer and press ⌘V. \(reason)"
                    : "Your newer clipboard was kept. Use Copy prompt below. \(reason)"
                env.recover(target.prompt, image, message)
                finish(.clipboardOnly(reason: reason))
            }
            guard let opened = await env.open(destination) else {
                manual("Couldn't open \(destination.name)."); return
            }
            guard current() else { return }
            // Browser login/readiness/composer state cannot be inferred from a process.
            guard !opened.isWeb else { manual("Paste the screenshot separately if included."); return }
            guard env.isTrusted() else { manual("Accessibility is needed for automatic paste."); return }

            // Opening has completed. Wait briefly for activation, then require stable
            // focus through the settle interval and before every payload operation.
            var arrived = false
            for _ in 0..<20 {
                guard current() else { return }
                if env.frontmostPID() == opened.pid { arrived = true; break }
                await env.sleep(0.15)
            }
            guard arrived else { manual("The AI app didn't come forward."); return }
            await env.sleep(opened.wasAlreadyRunning ? 0.35 : 1.5)
            guard current() else { return }
            @MainActor func canSend() -> Bool {
                current() && env.isTrusted() && env.frontmostPID() == opened.pid && staged.ownsClipboard
            }
            guard canSend() else { manual("Focus or clipboard changed; automatic paste stopped."); return }
            if let shortcut = destination.newChatShortcut {
                guard let (key, flags) = Keyboard.parse(shortcut), env.press(key, flags, opened.pid)
                else { manual("Couldn't start a new chat."); return }
                await env.sleep(0.6)
            }
            guard current() else { return }
            guard canSend(), env.editable(opened.pid) else {
                manual("Click the chat composer to paste."); return
            }
            if let image {
                guard destination.acceptsPastedImage, staged.put(image: image), canSend(),
                      env.press(9, .maskCommand, opened.pid) else {
                    manual("Use Copy screenshot to attach the image."); return
                }
                await env.sleep(0.7)
            }
            guard current() else { return }
            guard canSend(), env.editable(opened.pid), staged.put(text: target.prompt),
                  canSend(), env.press(9, .maskCommand, opened.pid) else {
                manual("Automatic paste stopped. You can finish it manually."); return
            }
            // Posting events isn't delivery confirmation. Keep both payloads available
            // for recovery even after returning the clipboard to its previous owner.
            env.recover(target.prompt, image, "Paste requested. Check the chat before sending. Copy either part again if needed.")
            await env.sleep(Pasteboard.restoreDelay)
            guard current() else { return }
            staged.restoreIfOwned()
            finish(.pasteRequested(hadImage: image != nil))
        }
    }
}
