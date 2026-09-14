import XCTest
@testable import AISlap

/// The gates are the whole product. A nudge that fires when it shouldn't is worse than
/// one that never fires, so most of these tests are about staying quiet.
@MainActor
final class NudgeEngineTests: XCTestCase {
    private let rulebookJSON = """
    {
      "schemaVersion": 1, "version": "test",
      "aiContexts": { "bundleIds": ["com.anthropic.claudefordesktop"], "browserTitlePatterns": ["Claude"] },
      "suppression": { "conferencingBundleIds": ["us.zoom.xos"] },
      "destinations": [{ "id": "claude", "name": "Claude",
        "bundleId": "com.anthropic.claudefordesktop", "webURL": "https://claude.ai/new",
        "newChatShortcut": "cmd+n", "acceptsPastedImage": true }],
      "browserBundleIds": ["com.google.Chrome"],
      "rules": [{
        "id": "doc.dwell", "enabled": true, "category": "doc",
        "match": { "extraBundleIds": ["com.example.writer"], "titlePatterns": [".*"] },
        "condition": { "dwellMs": 120000, "noAiContextForMs": 600000 },
        "confidence": 0.6, "cooldownMs": 1800000,
        "nudge": { "copy": "Blank page winning?", "promptTemplate": "Help me draft this." }
      }]
    }
    """

    private func makeEngine(clock: @escaping () -> Date) throws -> (NudgeEngine, UserDefaults, String) {
        let name = "AISlapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let book = try JSONDecoder().decode(Rulebook.self, from: Data(rulebookJSON.utf8))
        let engine = NudgeEngine(rulebook: book, handoff: Handoff(destinations: book.destinations),
                                 defaults: defaults, now: clock,
                                 suppressionCheck: { Suppression.Verdict(suppressed: false, reason: nil) })
        engine.quietHours = (23, 0)  // out of the way of a fixed test clock
        return (engine, defaults, name)
    }

    private let writer = WindowContext(
        bundleID: "com.example.writer", appName: "Writer", title: "Draft — chapter one"
    )

    /// Actual midday local, so no test ever trips over quiet hours.
    private func noon(_ offset: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: 1_789_153_200).addingTimeInterval(offset)
    }

    func testFiresOnlyAfterTheWholeDwell() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired: [String] = []
        engine.onNudge = { copy, _, _ in fired.append(copy) }

        engine.contextChanged(to: writer)
        t = 60; engine.tick()
        XCTAssertTrue(fired.isEmpty, "A minute in is not two minutes in")
        t = 121; engine.tick()
        XCTAssertEqual(fired, ["Blank page winning?"])
    }

    func testRecentAIUseBuysSilence() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired = 0
        engine.onNudge = { _, _, _ in fired += 1 }

        engine.markUsedAI()
        engine.contextChanged(to: writer)
        t = 300; engine.tick()
        XCTAssertEqual(fired, 0, "Five minutes after using AI is not failing to use AI")
        // The amnesty is ten minutes; past it the rule is allowed to speak.
        t = 700; engine.contextChanged(to: writer)
        t = 900; engine.tick()
        XCTAssertEqual(fired, 1)
    }

    func testTheSameWindowIsOnlyMentionedOnce() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired = 0
        engine.onNudge = { _, _, _ in fired += 1 }

        engine.contextChanged(to: writer)
        t = 121; engine.tick()
        XCTAssertEqual(fired, 1)

        // Past the rule's own half-hour cooldown, still sitting in the same window.
        // Only the "already said something about this one" gate can be holding it now,
        // which is the point of the test — an earlier version passed here purely
        // because the cooldown was doing the work.
        t = 2400; engine.tick()
        XCTAssertEqual(fired, 1, "Being told twice about one window is how a mascot gets muted")
    }

    func testTheDailyBudgetIsAHardStop() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        engine.dailyBudget = 1
        var fired = 0
        engine.onNudge = { _, _, _ in fired += 1 }

        engine.contextChanged(to: writer)
        t = 121; engine.tick()
        XCTAssertEqual(fired, 1)

        // A different window, well past the rule's cooldown, still gets nothing.
        t = 4000
        engine.contextChanged(to: WindowContext(
            bundleID: "com.example.writer", appName: "Writer", title: "Draft — chapter two"))
        t = 4200; engine.tick()
        XCTAssertEqual(fired, 1, "Budget spent means quiet for the rest of the day")
    }

    func testSnoozeSilencesItAndThenWearsOff() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired = 0
        engine.onNudge = { _, _, _ in fired += 1 }

        engine.snooze(minutes: 30)
        engine.contextChanged(to: writer)
        t = 300; engine.tick()
        XCTAssertEqual(fired, 0)

        t = 2000  // past the half hour
        engine.contextChanged(to: writer)
        t = 2200; engine.tick()
        XCTAssertEqual(fired, 1)
    }

    func testSwitchingOffMeansOff() throws {
        var t: TimeInterval = 0
        let (engine, _, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        var fired = 0
        engine.onNudge = { _, _, _ in fired += 1 }

        engine.isEnabled = false
        engine.contextChanged(to: writer)
        t = 600; engine.tick()
        XCTAssertEqual(fired, 0)
        XCTAssertNil(engine.dwellProgress(), "Doug must not look up either")
    }

    /// The reason the log was removed. If this ever needs a file, that is a product
    /// decision and not an implementation detail.
    func testNothingAboutYourDayIsWrittenDown() throws {
        var t: TimeInterval = 0
        let (engine, defaults, name) = try makeEngine { self.noon(t) }
        defer { UserDefaults().removePersistentDomain(forName: name) }
        engine.onNudge = { _, _, _ in }

        engine.contextChanged(to: writer)
        t = 121; engine.tick()
        engine.contextEnded()

        let stored = defaults.dictionaryRepresentation().keys.sorted()
        for key in stored {
            XCTAssertFalse(key.contains("surface") || key.contains("context") || key.contains("history"),
                           "\(key) looks like activity history")
        }
        let written = stored.map { "\(defaults.object(forKey: $0) ?? "")" }.joined()
        XCTAssertFalse(written.contains("chapter one"), "A window title reached the defaults")
        XCTAssertFalse(written.contains("Writer"), "An app name reached the defaults")
    }
}
