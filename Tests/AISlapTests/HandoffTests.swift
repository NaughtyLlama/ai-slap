import XCTest
import AppKit
@testable import AISlap

@MainActor
final class HandoffTests: XCTestCase {
    private func board() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("AISlapTests.\(UUID().uuidString)")) }
    private let destination = AIDestination(id: "fake", name: "AI", bundleId: nil,
        webURL: "https://example.invalid", newChatShortcut: "cmd+n", acceptsPastedImage: true)
    private var target: Handoff.Target { Handoff.Target(pid: 42, title: "Source", prompt: "Help with this") }

    func testClipboardRestoreDoesNotOverwriteNewUserCopy() {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        let stage = Pasteboard.beginStaging(on: pb)
        XCTAssertTrue(stage.put(text: "payload"))
        pb.clearContents(); pb.setString("new user copy", forType: .string)
        XCTAssertFalse(stage.restoreIfOwned())
        XCTAssertFalse(stage.put(text: "late payload"))
        XCTAssertEqual(pb.string(forType: .string), "new user copy")
    }

    func testClipboardRestoresOriginalAndRejectsOlderTransaction() {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        let first = Pasteboard.beginStaging(on: pb)
        first.put(text: "first")
        let second = Pasteboard.beginStaging(on: pb)
        second.put(text: "second")
        XCTAssertFalse(first.restoreIfOwned())
        XCTAssertEqual(pb.string(forType: .string), "second")
        XCTAssertTrue(second.restoreIfOwned())
        XCTAssertEqual(pb.string(forType: .string), "first")
    }

    private func environment(_ pb: NSPasteboard) -> Handoff.Environment {
        var env = Handoff.Environment()
        env.hasScreenPermission = { false }
        env.capture = { _ in XCTFail("Must not capture without permission"); return nil }
        env.review = { _, _ in .textOnly }
        env.requestPermission = { XCTFail("Text-only must not request permission") }
        env.open = { _ in AIDestination.Opened(pid: 99, bundleID: "fake", wasAlreadyRunning: true, isWeb: false) }
        env.frontmostPID = { 99 }
        env.isTrusted = { true }
        env.editable = { _ in true }
        env.press = { _, _, _ in true }
        env.stage = { Pasteboard.beginStaging(on: pb) }
        env.recover = { _, _, _ in }
        env.clearRecovery = {}
        env.sleep = { _ in }
        return env
    }

    private func run(_ handoff: Handoff) async -> Handoff.Result {
        await withCheckedContinuation { continuation in
            handoff.run(target) { continuation.resume(returning: $0) }
        }
    }

    func testBrowserNeverSendsNativeShortcutsOrPasteEvents() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        env.open = { _ in AIDestination.Opened(pid: 88, bundleID: "browser", wasAlreadyRunning: true, isWeb: true) }
        env.press = { _, _, _ in XCTFail("Web handoff must use explicit paste"); return false }
        var recovered = false
        env.recover = { prompt, _, _ in recovered = prompt == self.target.prompt }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .clipboardOnly = result else { return XCTFail("Expected manual paste") }
        XCTAssertTrue(recovered)
        XCTAssertEqual(pb.string(forType: .string), target.prompt)
    }

    func testFocusChangeDuringSettleSendsNothing() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        var foreground: pid_t = 99
        env.frontmostPID = { foreground }
        env.sleep = { _ in foreground = 101 }
        env.press = { _, _, _ in XCTFail("Focus changed"); return false }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .clipboardOnly = result else { return XCTFail("Expected manual paste") }
    }

    func testCopyDuringOpenIsNeverOverwritten() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        env.open = { _ in
            pb.clearContents(); pb.setString("user copied while opening", forType: .string)
            return AIDestination.Opened(pid: 99, bundleID: "fake", wasAlreadyRunning: true, isWeb: false)
        }
        env.press = { _, _, _ in XCTFail("Clipboard changed"); return false }
        _ = await run(Handoff(destinations: [destination], environment: env))
        XCTAssertEqual(pb.string(forType: .string), "user copied while opening")
    }

    func testDeniedAccessibilityKeepsExplicitFallback() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        env.isTrusted = { false }
        env.press = { _, _, _ in XCTFail("Permission denied"); return false }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .clipboardOnly = result else { return XCTFail("Expected fallback") }
        XCTAssertEqual(pb.string(forType: .string), target.prompt)
    }

    func testNativePasteIsTargetedAndRestoresOwnedClipboard() async {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        var env = environment(pb)
        var keys: [CGKeyCode] = []
        env.press = { key, _, pid in XCTAssertEqual(pid, 99); keys.append(key); return true }
        var recoveryShown = false
        env.recover = { _, _, _ in recoveryShown = true }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .pasteRequested(let hadImage) = result else { return XCTFail("Expected honest requested status") }
        XCTAssertFalse(hadImage)
        XCTAssertEqual(keys, [45, 9])
        XCTAssertEqual(pb.string(forType: .string), "original")
        XCTAssertFalse(recoveryShown, "A handoff that worked must not leave a panel to dismiss")
    }

    func testCancelReviewDoesNotOpenOrStage() async {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        var env = environment(pb)
        env.review = { _, _ in .cancel }
        env.open = { _ in XCTFail("Cancelled"); return nil }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .cancelled = result else { return XCTFail("Expected cancelled") }
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    /// One pixel is enough: these tests care that an image travels, not what is in it.
    private static func pixel() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// A screenshot handoff is two pastes, and the window between them is real: the user
    /// can click away after the image lands and before the prompt does. The text must not
    /// be typed into whatever they switched to.
    func testFocusLostBetweenImageAndTextStopsBeforeTheText() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        env.hasScreenPermission = { true }
        env.capture = { _ in Self.pixel() }
        env.review = { _, _ in .includeImage }
        env.requestPermission = { XCTFail("Permission was already granted") }
        var foreground: pid_t = 99
        env.frontmostPID = { foreground }
        var keys: [CGKeyCode] = []
        env.press = { key, _, pid in
            XCTAssertEqual(pid, 99)
            keys.append(key)
            if key == 9 { foreground = 101 }  // they clicked away the moment the image landed
            return true
        }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .clipboardOnly = result else { return XCTFail("Expected manual paste") }
        XCTAssertEqual(keys, [45, 9], "New chat and the image, and then nothing")
    }

    /// Erase and pause both cancel mid-flight. A delayed step must not wake up afterwards
    /// and press anything, report a result, or leave the payload on the clipboard.
    func testCancelDuringAnAwaitedStepSendsNothingAndReportsNothing() async {
        let pb = board(); defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        var env = environment(pb)
        var pressed: [CGKeyCode] = []
        env.press = { key, _, _ in pressed.append(key); return true }
        var handoff: Handoff?
        env.sleep = { _ in handoff?.cancel() }
        let subject = Handoff(destinations: [destination], environment: env)
        handoff = subject
        let silence = expectation(description: "a cancelled handoff never completes")
        silence.isInverted = true
        subject.run(target) { _ in silence.fulfill() }
        await fulfillment(of: [silence], timeout: 0.4)
        XCTAssertTrue(pressed.isEmpty)
        XCTAssertNil(subject.lastResult)
        XCTAssertEqual(pb.string(forType: .string), "original")
    }

    /// The destination failing to open is the one moment a capture is most expensive to
    /// lose: it was taken, reviewed and approved. It has to survive into the recovery UI.
    func testOpenFailureKeepsTheApprovedScreenshotRecoverable() async {
        let pb = board(); defer { pb.releaseGlobally() }
        var env = environment(pb)
        env.hasScreenPermission = { true }
        env.capture = { _ in Self.pixel() }
        env.review = { _, _ in .includeImage }
        env.requestPermission = { XCTFail("Permission was already granted") }
        env.open = { _ in nil }
        env.press = { _, _, _ in XCTFail("Nothing opened"); return false }
        var recoveredPrompt: String?
        var recoveredImage: CGImage?
        env.recover = { prompt, image, _ in recoveredPrompt = prompt; recoveredImage = image }
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .clipboardOnly(let reason) = result else { return XCTFail("Expected manual paste") }
        XCTAssertTrue(reason.contains("Couldn't open"))
        XCTAssertEqual(recoveredPrompt, target.prompt)
        XCTAssertNotNil(recoveredImage, "The screenshot must not be dropped on the floor")
        XCTAssertEqual(pb.string(forType: .string), target.prompt)
    }

    /// "Don't ask again" has to actually stop asking, and the menu tick has to be a way
    /// back — a preference you can set and not clear is a trap, not a setting.
    func testSkippingTheReviewIsRememberedAndReversible() {
        let key = "handoffReview"
        let previous = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        HandoffRecovery.preference = .ask
        XCTAssertEqual(HandoffRecovery.preference, .ask)

        HandoffRecovery.preference = .alwaysInclude
        XCTAssertEqual(HandoffRecovery.preference, .alwaysInclude)
        // Skipping must not become a modal by another name: with a preference set, the
        // review answers itself and never reaches an alert.
        XCTAssertEqual(HandoffRecovery.review(image: Self.pixel(), hasPermission: true), .includeImage)
        // No screenshot to include is not a reason to start asking again.
        XCTAssertEqual(HandoffRecovery.review(image: nil, hasPermission: true), .textOnly)

        HandoffRecovery.preference = .alwaysTextOnly
        XCTAssertEqual(HandoffRecovery.review(image: Self.pixel(), hasPermission: true), .textOnly)

        HandoffRecovery.preference = .ask
        XCTAssertEqual(HandoffRecovery.preference, .ask)
    }

    func testNoSubmitShortcutCanBeParsed() { XCTAssertNil(Keyboard.parse("cmd+return")) }
}
