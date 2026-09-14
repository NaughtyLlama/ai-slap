import XCTest
@testable import AISlap

/// These run against the **shipping nine-rule configuration**, not a synthetic one.
/// The bugs that got past the first round of engine tests were all in the interaction
/// between real rules — a broad rule outranking and silently blocking narrower ones —
/// which a single invented rule cannot show.
@MainActor
final class RulebookCoverageTests: XCTestCase {
    private func shippingRulebook() throws -> Rulebook {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/rulebook.json")
        return try JSONDecoder().decode(Rulebook.self, from: Data(contentsOf: url))
    }

    private func makeEngine(_ book: Rulebook, clock: @escaping () -> Date)
        -> (NudgeEngine, String)
    {
        let name = "AISlapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let engine = NudgeEngine(
            rulebook: book, handoff: Handoff(destinations: book.destinations),
            defaults: defaults, now: clock,
            suppressionCheck: { Suppression.Verdict(suppressed: false, reason: nil) })
        engine.quietHours = (23, 0)
        return (engine, name)
    }

    private func noon(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_789_153_200).addingTimeInterval(offset)
    }

    /// A Gmail inbox in Chrome. Three rules claim it, which is what makes it the right
    /// shape for testing the queue.
    private let inbox = WindowContext(
        bundleID: "com.google.Chrome", appName: "Google Chrome",
        title: "Inbox (12) - chen@example.com - Gmail"
    )
    /// A browser window that no content rule claims.
    private let browsing = WindowContext(
        bundleID: "com.google.Chrome", appName: "Google Chrome", title: "Some tool - Dashboard"
    )

    /// One real window per rule. A rule that can never be a candidate is dead weight
    /// that still reads as a feature in the menu and the notes.
    private func sampleWindows() -> [(rule: String, context: WindowContext)] {
        func chrome(_ title: String) -> WindowContext {
            WindowContext(bundleID: "com.google.Chrome", appName: "Google Chrome", title: title)
        }
        return [
            ("email.message.dwell", chrome("Re: the thing - chen@example.com - Gmail")),
            ("email.inbox.dwell", chrome("Inbox (12) - chen@example.com - Gmail")),
            ("chat.thread.dwell", chrome("general - Slack")),
            ("doc.dwell", chrome("Chapter one - Google Docs")),
            ("sheet.dwell", chrome("Q3 numbers - Google Sheets")),
            ("search.repeated", chrome("swift concurrency - Google Search")),
            ("surface.returns", chrome("Some tool - Dashboard")),
            ("surface.grind", chrome("Some tool - Dashboard")),
        ]
    }

    func testEveryEnabledRuleCanBeOffered() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }

        for sample in sampleWindows() {
            let offered = engine.candidates(for: sample.context).map(\.id)
            XCTAssertTrue(offered.contains(sample.rule),
                          "\(sample.rule) is switched on but never offered for a window "
                          + "it is written for: \"\(sample.context.title ?? "")\"")
        }

        // The one that was genuinely unreachable. Its matcher returns false for every
        // window, and two rules match anything, so the old "nobody claimed it" fallback
        // could never run.
        XCTAssertTrue(engine.candidates(for: sampleWindows().last!.context)
            .contains { $0.id == "surface.grind" })

        // And the one the rulebook has deliberately switched off stays off.
        let enabled = Set(book.rules.filter(\.enabled).map(\.id))
        XCTAssertFalse(enabled.contains("timer.checkin"),
                       "timer.checkin is disabled in the rulebook; if that changes, give "
                       + "it a sample window above")
    }

    /// The bug that hid two rules. `surface.returns` matches any window and outranks
    /// both `timer.checkin` and `email.inbox.dwell`. Blocking it must not silence them.
    func testABlockedBroadRuleDoesNotSuppressTheOnesBeneathIt() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired: [String] = []
        engine.onNudge = { _, _, ruleID in fired.append(ruleID) }

        let ordered = engine.candidates(for: inbox).map(\.id)
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: "surface.returns")),
                          try XCTUnwrap(ordered.firstIndex(of: "email.inbox.dwell")),
                          "returns outranks the inbox rule, which is the setup for the bug")

        engine.contextChanged(to: inbox)
        let returns = try XCTUnwrap(engine.candidates(for: inbox)
            .first { $0.id == "surface.returns" })
        if case .pass = engine.gate(returns, context: inbox) {
            XCTFail("returns should be blocked — one visit, not twelve")
        }

        t = 300  // past the inbox rule's four minutes
        engine.tick()
        XCTAssertEqual(fired, ["email.inbox.dwell"],
                       "a rule failing its own condition must step aside, not block")
    }

    func testDougWaitsOnTheRuleThatCanActuallyFire() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }

        engine.contextChanged(to: inbox)
        t = 120  // half of the timer rule's 25 minutes
        let progress = try XCTUnwrap(engine.dwellProgress())
        XCTAssertEqual(progress, 0.5, accuracy: 0.05,
                       "progress must track the rule that will fire, not a blocked one")
    }

    /// The nudge the product must never send.
    ///
    /// The only AI check was a grace window measured from the moment you *arrived* in
    /// the AI, so the longer you actually worked there the more expired that grace
    /// became. Half an hour into a Claude window, `surface.grind` — which fires on time
    /// totalled across the day and deliberately claims any surface no other rule
    /// wants — looks at a surface with thirty banked minutes and a grace that lapsed
    /// twenty minutes ago, and tells you to try using AI.
    func testItNeverNudgesYouInsideTheAIItself() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired: [String] = []
        engine.onNudge = { _, _, ruleID in fired.append(ruleID) }

        let claude = WindowContext(bundleID: "com.google.Chrome",
                                   appName: "Google Chrome", title: "Claude")
        XCTAssertTrue(engine.isAIContext(claude),
                      "the whole test depends on this window being recognised as AI")

        engine.contextChanged(to: claude)
        for minute in 1...30 {
            t = TimeInterval(minute) * 60
            engine.tick()
        }
        XCTAssertEqual(fired, [],
                       "told to use AI while using AI: \(fired)")
    }

    /// Not even the cheap tier. Doug turning to face a Claude window is the same
    /// accusation in a quieter voice, and it is the tell that the gate is only
    /// half-closed. The browser window is the one that can prove it: `surface.grind`
    /// really is a live candidate there, and really does pass its gates at half an hour.
    func testDougDoesNotLookUpInsideTheAIEither() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }

        let claude = WindowContext(bundleID: "com.google.Chrome",
                                   appName: "Google Chrome", title: "Claude")
        engine.contextChanged(to: claude)
        t = 1_800
        XCTAssertNil(engine.dwellProgress(),
                     "nothing is being waited on when you are already in the AI")
    }

    /// A native AI client is blocked today only because no rule happens to reach it —
    /// `surface.grind` is browser-only and `surface.returns` wants twelve visits. That
    /// is luck, not a decision, and it evaporates the moment a rule like `timer.checkin`
    /// is switched on. So the assertion is on *why* it was blocked.
    func testTheNativeAIClientIsBlockedOnPurposeAndNotByAccident() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }

        let claude = WindowContext(bundleID: "com.anthropic.claudefordesktop",
                                   appName: "Claude", title: "Untitled")
        engine.contextChanged(to: claude)
        t = 1_800
        let anyRule = try XCTUnwrap(engine.candidates(for: claude).first)
        guard case .blocked(let why) = engine.gate(anyRule, context: claude) else {
            return XCTFail("\(anyRule.id) would fire inside the AI client itself")
        }
        XCTAssertTrue(why.lowercased().contains("ai"),
                      "blocked for the wrong reason — \"\(why)\" is a condition that "
                      + "failed, not a decision that this is the AI")
    }

    /// The regression that made the whole product inert, and was invisible because its
    /// symptom is *silence*.
    ///
    /// Every rule waits out a grace window since you last touched AI. Set that window
    /// longer than the gap between someone's AI sessions and nothing can ever fire —
    /// not one rule, not once, all day. At ten minutes, a real day of switching windows
    /// every minute or two while using Claude every seven produced exactly zero nudges,
    /// and the app looked switched off rather than broken.
    ///
    /// So this is a test about a *person*, not a rule: someone who uses AI regularly
    /// must still be reachable. It fails the moment the grace grows past the gap.
    func testSomeoneWhoUsesAIAllDayCanStillBeNudged() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired: [String] = []
        engine.onNudge = { _, _, ruleID in fired.append(ruleID) }

        let claude = WindowContext(bundleID: "com.anthropic.claudefordesktop",
                                   appName: "Claude", title: "Claude")
        let email = WindowContext(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                  title: "Re: the quote - chen@example.com - Gmail")

        // Four rounds of: four minutes in Claude, then three minutes stuck on one email.
        // Nobody in this loop goes ten minutes without AI, which is the whole point.
        for _ in 0..<4 {
            engine.contextChanged(to: claude)
            let leaveAI = t + 240
            while t < leaveAI { t += 5; engine.tick() }

            engine.contextChanged(to: email)
            let leaveEmail = t + 180
            while t < leaveEmail { t += 5; engine.tick() }
        }

        XCTAssertFalse(fired.isEmpty,
                       "silent for the entire day — the grace window is longer than the "
                       + "gap between this person's AI sessions, so no rule can reach them")
    }

    /// Turning the watching off has to drop what was being held about today, not just
    /// stop mentioning it. The accumulation rule is the honest test: it fires on time
    /// totalled across the day, so if forgetting works, its gate closes again.
    func testSwitchingOffForgetsWhereYouHaveBeen() throws {
        let book = try shippingRulebook()
        var t: TimeInterval = 0
        let (engine, name) = makeEngine(book) { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let tool = WindowContext(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                 title: "Some tool - Dashboard")
        let grind = try XCTUnwrap(engine.candidates(for: tool).first { $0.id == "surface.grind" })

        let elsewhere = WindowContext(bundleID: "com.google.Chrome",
                                      appName: "Google Chrome", title: "Other thing - Page")

        // Twenty minutes on the surface, then away, so the time is banked in the day's
        // totals rather than still running on the current sit. That distinction is the
        // whole point: an earlier version of this test passed with the totals left
        // intact, because clearing the *current* context was enough to close the gate.
        engine.contextChanged(to: tool)
        t = 1_200; engine.contextChanged(to: elsewhere)
        t = 1_260; engine.contextChanged(to: tool)
        t = 1_320
        guard case .pass = engine.gate(grind, context: tool) else {
            return XCTFail("twenty banked minutes should satisfy the accumulation rule")
        }

        engine.forgetEverything()
        XCTAssertNil(engine.dwellProgress(), "nothing should be under observation")

        // Back on the same surface, with only seconds on the clock. If the banked total
        // survived, this still passes — which is what forgetting has to prevent.
        engine.contextChanged(to: tool)
        t = 1_380
        guard case .blocked = engine.gate(grind, context: tool) else {
            return XCTFail("the day's totals survived being told to forget them")
        }
    }
}
