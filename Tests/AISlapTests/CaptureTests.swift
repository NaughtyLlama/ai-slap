import XCTest
@testable import AISlap

/// Which window gets photographed is the only judgement call left in this app, and the
/// only place it can quietly do the wrong thing.
final class CaptureTests: XCTestCase {
    private func win(_ title: String?, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 800, _ h: CGFloat = 600)
        -> WindowCapture.Candidate
    {
        WindowCapture.Candidate(title: title, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    func testCaptureNeverSubstitutesAnUnrelatedWindow() {
        // Several windows, no test agrees: refuse rather than guess.
        XCTAssertNil(WindowCapture.choose(
            [win("Another", 0, 0), win("A third", 900, 0)], title: "Original", focused: nil))
        // Two windows with the same title is exactly the ambiguity worth refusing,
        // and their positions are what separates them.
        XCTAssertNil(WindowCapture.choose(
            [win("Original", 0, 0), win("Original", 900, 0)], title: "Original", focused: nil))
        XCTAssertNil(WindowCapture.choose(
            [win(nil, 0, 0), win("Original", 900, 0)], title: nil, focused: nil))
    }

    /// The app the user is looking at owns exactly one window, so there is no second
    /// window to mistake it for, and no title has to agree for it to be safe.
    func testSingleWindowNeedsNoAgreementAtAll() {
        XCTAssertEqual(WindowCapture.choose(
            [win("Teddy (@WarnerTeddy) / X", 0, 0)],
            title: "Teddy (@WarnerTeddy) / X — Google Chrome", focused: nil)?.how, .onlyWindow)
        XCTAssertEqual(WindowCapture.choose([win(nil, 0, 0)], title: nil, focused: nil)?.index, 0)
        XCTAssertNil(WindowCapture.choose([], title: "Original", focused: nil))
    }

    /// Titles work for some apps and not others, so keep them — but only as one of
    /// three tests, and only when they single a window out.
    func testTitleStillWinsWhenItIsUnique() {
        let choice = WindowCapture.choose(
            [win("Other", 0, 0), win("Original", 900, 0)], title: "Original", focused: nil)
        XCTAssertEqual(choice?.index, 1)
        XCTAssertEqual(choice?.how, .title)
    }

    /// The test that saves the apps where the two APIs disagree about names. A window
    /// is in exactly one place, and both APIs report a frame.
    func testPositionIdentifiesTheWindowWhenTitlesDisagree() {
        let windows = [win("Notes — Obsidian", 0, 0), win("Draft — Obsidian", 900, 100)]
        let choice = WindowCapture.choose(
            windows, title: "Draft", focused: CGRect(x: 900, y: 100, width: 800, height: 600))
        XCTAssertEqual(choice?.index, 1)
        XCTAssertEqual(choice?.how, .position)
    }

    /// Rounding between the two APIs must not lose the window, and a genuinely
    /// different window must not be accepted.
    func testPositionToleratesRoundingButNotADifferentWindow() {
        let windows = [win("A", 0, 0), win("B", 900, 100)]
        XCTAssertEqual(WindowCapture.choose(
            windows, title: nil, focused: CGRect(x: 901, y: 101, width: 799, height: 599))?.index, 1)
        XCTAssertNil(WindowCapture.choose(
            windows, title: nil, focused: CGRect(x: 400, y: 300, width: 800, height: 600)))
    }

}
