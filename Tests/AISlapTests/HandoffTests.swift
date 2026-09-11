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
        let result = await run(Handoff(destinations: [destination], environment: env))
        guard case .pasteRequested(let hadImage) = result else { return XCTFail("Expected honest requested status") }
        XCTAssertFalse(hadImage)
        XCTAssertEqual(keys, [45, 9])
        XCTAssertEqual(pb.string(forType: .string), "original")
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

    func testNoSubmitShortcutCanBeParsed() { XCTAssertNil(Keyboard.parse("cmd+return")) }
}
