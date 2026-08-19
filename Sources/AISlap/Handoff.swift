import AppKit

/// The six steps of docs/05, in order: capture the window, build the prompt, stage the
/// pasteboard, open the destination, wait for it, paste — and never submit.
///
/// The clipboard is the universal fallback. Every failure path below still leaves the
/// payload one Cmd-V away, so the user is never stranded with a broken interaction and
/// no recourse.
final class Handoff {

    struct Target {
        let pid: pid_t
        let title: String?
        let prompt: String
    }

    enum Result {
        case pasted(hadImage: Bool)
        case clipboardOnly(reason: String)
        case failed(String)
    }

    /// How long to wait for the destination to come forward before giving up and
    /// leaving the payload on the clipboard.
    private let activationTimeout: TimeInterval = 2.0

    private let destinations: [AIDestination]
    private var hasExplainedScreenRecording = false

    init(destinations: [AIDestination]) {
        self.destinations = destinations
    }

    var preferredDestination: AIDestination? {
        destinations.first { $0.isNativeAvailable } ?? destinations.first { $0.isAvailable }
    }

    func run(_ target: Target, completion: @escaping (Result) -> Void) {
        guard let destination = preferredDestination else {
            completion(.failed("No AI destination is configured."))
            return
        }

        // Step 2. Screen Recording is requested here and nowhere else — docs/02 keeps
        // it out of onboarding on purpose. A denial costs the screenshot, not the flow.
        let wantsImage = WindowCapture.hasPermission
            || !hasExplainedScreenRecording

        Task { @MainActor in
            var image: CGImage?
            if wantsImage {
                if WindowCapture.hasPermission {
                    image = await WindowCapture.capture(
                        pid: target.pid, title: target.title
                    )
                } else {
                    hasExplainedScreenRecording = true
                    if case .granted = WindowCapture.requestPermission() {
                        image = await WindowCapture.capture(
                            pid: target.pid, title: target.title
                        )
                    }
                }
            }

            // Steps 3 and 4. The prompt is the rule's template verbatim: docs/05 forbids
            // interpolating anything from the screen, and the window title in particular
            // has already been reduced to a category token and discarded.
            Pasteboard.stage(text: target.prompt, image: image)

            // Step 5.
            guard let expectedBundleID = destination.open() else {
                completion(.clipboardOnly(reason: "couldn't open \(destination.name)"))
                return
            }

            self.whenFrontmost(expectedBundleID) { arrived in
                guard arrived else {
                    completion(.clipboardOnly(
                        reason: "\(destination.name) didn't come forward"
                    ))
                    return
                }
                // Step 6. Paste only. Never Return — the user reads what is about to be
                // sent and sends it themselves. Non-negotiable in docs/05.
                let pasted = Pasteboard.synthesizePaste()
                completion(pasted
                    ? .pasted(hadImage: image != nil)
                    : .clipboardOnly(reason: "paste didn't go through"))
            }
        }
    }

    private func whenFrontmost(
        _ bundleID: String, completion: @escaping (Bool) -> Void
    ) {
        let deadline = Date().addingTimeInterval(activationTimeout)

        func poll() {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                // A beat for the composer to take focus before the keystroke lands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    completion(true)
                }
                return
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }
}
