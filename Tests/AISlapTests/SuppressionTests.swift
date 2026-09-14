import XCTest
@testable import AISlap

/// "Never during a call" was a promise the old check could not keep: it asked whether a
/// listed conferencing app was *frontmost*, so switching to a document to take notes
/// removed the protection, and a meeting in a browser tab was never covered at all.
final class SuppressionTests: XCTestCase {
    private func make(mic: @escaping () -> Bool,
                      frontmost: @escaping () -> (id: String, name: String?)?,
                      clock: @escaping () -> Date) -> Suppression {
        let s = Suppression(conferencingBundleIDs: ["us.zoom.xos"])
        s.micInUse = mic
        s.frontmostBundleID = frontmost
        s.now = clock
        return s
    }

    private func noon(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_789_153_200).addingTimeInterval(offset)
    }

    func testACallProtectsYouAfterYouSwitchAwayFromTheCallApp() {
        var t: TimeInterval = 0
        var front: (id: String, name: String?)? = ("us.zoom.xos", "zoom.us")
        let s = make(mic: { true }, frontmost: { front }, clock: { self.noon(t) })

        XCTAssertTrue(s.check().suppressed, "on a call, in the call app")

        // The scenario the old check missed entirely: still on the call, now taking
        // notes in a document.
        front = ("com.google.Chrome", "Google Chrome")
        XCTAssertTrue(s.check().suppressed, "still on the call, just looking elsewhere")
    }

    func testAMeetingInABrowserTabCounts() {
        let s = make(mic: { true },
                     frontmost: { ("com.google.Chrome", "Google Chrome") },
                     clock: { self.noon() })
        XCTAssertTrue(s.check().suppressed,
                      "no bundle-id list will ever contain every way to hold a meeting")
    }

    func testTheProtectionTrailsOffAfterYouHangUp() {
        var t: TimeInterval = 0
        var onCall = true
        let s = make(mic: { onCall },
                     frontmost: { ("com.google.Chrome", "Google Chrome") },
                     clock: { self.noon(t) })

        XCTAssertTrue(s.check().suppressed)
        onCall = false
        t = 30
        XCTAssertTrue(s.check().suppressed, "writing up the meeting is still the meeting")
        t = 200  // past the two-minute tail
        XCTAssertFalse(s.check().suppressed)
    }

    func testAnIdleMicWithNoCallAppIsNotSuppressed() {
        let s = make(mic: { false },
                     frontmost: { ("com.google.Chrome", "Google Chrome") },
                     clock: { self.noon() })
        XCTAssertFalse(s.check().suppressed, "otherwise the app would never say anything")
    }

    /// ⌥⌘G. The shortcut exists for the moment before a screen share, so it has to stop
    /// a nudge arriving, not merely hide the crab.
    func testTheHideShortcutSilencesEverything() {
        var t: TimeInterval = 0
        let s = make(mic: { false },
                     frontmost: { ("com.example.doc", "Writer") },
                     clock: { self.noon(t) })
        XCTAssertFalse(s.check().suppressed)

        s.panic()
        XCTAssertTrue(s.check().suppressed, "hiding for a demo must stop nudges too")
        XCTAssertTrue(s.isPanicked)

        s.cancelPanic()
        XCTAssertFalse(s.check().suppressed, "and bringing him back must undo it")
    }

    /// Hiding him for a screen share used to wear off after thirty minutes while the
    /// crab stayed hidden. A long demo therefore ended with a speech bubble on the
    /// shared screen and no visible mascot to explain it — the exact accident the
    /// shortcut exists to prevent, arriving half an hour late.
    func testHidingLastsUntilYouBringHimBack() {
        var t: TimeInterval = 0
        let s = make(mic: { false },
                     frontmost: { ("com.example.doc", "Writer") },
                     clock: { self.noon(t) })

        s.panic()
        t = 31 * 60
        XCTAssertTrue(s.check().suppressed, "a demo can run longer than half an hour")
        t = 3 * 3_600
        XCTAssertTrue(s.check().suppressed, "and longer than that")
        XCTAssertTrue(s.isPanicked)

        s.cancelPanic()
        XCTAssertFalse(s.check().suppressed)
    }

    /// The one thing that does lift it on its own. Hidden on Monday and forgotten is an
    /// app that silently does nothing forever, so the hide lapses at the end of the day
    /// — and the crab comes back with it, which is what keeps the two from disagreeing.
    func testAForgottenHideLapsesOvernight() {
        var t: TimeInterval = 0
        let s = make(mic: { false },
                     frontmost: { ("com.example.doc", "Writer") },
                     clock: { self.noon(t) })

        s.panic()
        let tomorrow = Calendar.current.startOfDay(for: noon())
            .addingTimeInterval(86_400 + 3_600)
        t = tomorrow.timeIntervalSince(noon())
        XCTAssertFalse(s.check().suppressed, "a new day starts him visible")
        XCTAssertFalse(s.isPanicked, "and the menu must agree with the check")
    }

    func testACallAppInFrontBeforeAnyoneUnmutesStillCounts() {
        let s = make(mic: { false },
                     frontmost: { ("us.zoom.xos", "zoom.us") },
                     clock: { self.noon() })
        XCTAssertTrue(s.check().suppressed, "a call about to start is a call")
    }
}
