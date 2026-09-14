import AppKit
import CoreAudio

/// When the interruption must not appear at all.
///
/// docs/04 is blunt about why this gets its own section: a mascot appearing during a
/// board demo is the anecdote that kills the company. The asymmetry drives the design —
/// **hiding when you didn't need to costs nothing; failing to hide once costs the
/// account** — so every check here errs toward hiding.
final class Suppression {

    private let conferencingBundleIDs: Set<String>
    private var panicUntil: Date?
    private var screenIsLocked = false
    private var lastMicUse: Date?
    /// Long enough to cover "let me just write that down", short enough not to eat the
    /// rest of your morning.
    private static let afterCallGrace: TimeInterval = 120

    /// Injected so tests do not depend on whether the machine running them is on a call.
    var micInUse: () -> Bool = Suppression.defaultMicInUse
    var now: () -> Date = Date.init
    var frontmostBundleID: () -> (id: String, name: String?)? = {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName)
    }

    /// Whether anything on this Mac is using the default input device. No permission is
    /// required to ask, and asking prompts nothing.
    static func defaultMicInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
              ) == noErr, deviceID != kAudioObjectUnknown else { return false }

        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// docs/04: the panic hotkey hides everything for half an hour. Users need to trust
    /// they can make it vanish in one keystroke or they won't run it at all.
    static let panicDuration: TimeInterval = 30 * 60

    init(conferencingBundleIDs: [String]) {
        self.conferencingBundleIDs = Set(conferencingBundleIDs)
        observeScreenLock()
    }

    struct Verdict {
        let suppressed: Bool
        let reason: String?
    }

    func check() -> Verdict {
        if let panicUntil, now() < panicUntil {
            let minutes = Int(panicUntil.timeIntervalSinceNow / 60) + 1
            return Verdict(suppressed: true, reason: "hidden for another \(minutes)m")
        }
        if screenIsLocked {
            return Verdict(suppressed: true, reason: "screen locked")
        }
        // The real test for "on a call", and the only one that survives you switching
        // away from the call app to take notes. It also catches the cases a bundle-id
        // list never will: a meeting in a browser tab, a Slack huddle, FaceTime.
        //
        // Asking whether the default input device is running needs no permission and
        // prompts nothing. ⚠️ Verified to return false when idle and to cost nothing;
        // not yet watched returning true during an actual call.
        if micInUse() {
            lastMicUse = now()
            return Verdict(suppressed: true, reason: "your microphone is in use")
        }
        // A short tail after the mic stops. Hanging up and immediately writing notes is
        // still the meeting, and a crab arriving three seconds after goodbye is worse
        // than one arriving during.
        if let lastMicUse, now().timeIntervalSince(lastMicUse) < Self.afterCallGrace {
            return Verdict(suppressed: true, reason: "you just finished a call")
        }
        // Kept as a belt to the microphone's braces: a call app in front before anyone
        // has unmuted is still a call about to start.
        if let app = frontmostBundleID(), conferencingBundleIDs.contains(app.id) {
            return Verdict(
                suppressed: true,
                reason: "\(app.name ?? "a call app") is in front"
            )
        }
        return Verdict(suppressed: false, reason: nil)
    }

    func panic() {
        panicUntil = now().addingTimeInterval(Self.panicDuration)
    }

    func cancelPanic() {
        panicUntil = nil
    }

    var isPanicked: Bool {
        guard let panicUntil else { return false }
        return now() < panicUntil
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.screenIsLocked = true }
        center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.screenIsLocked = false }
    }
}
