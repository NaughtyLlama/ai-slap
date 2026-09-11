import XCTest
import SQLite3
@testable import AISlap

final class PrivacyTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_789_056_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func sql(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "test.sqlite", code: Int(sqlite3_errcode(db)))
        }
    }
    private func count(_ store: SessionStore, _ table: String) -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(store.db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(stmt, 0))
    }
    private func session(title: String = "Private account - Chrome", end: Date? = nil) -> Session {
        let end = end ?? instant
        return Session(context: WindowContext(bundleID: "com.google.Chrome", appName: "Chrome", title: title),
                       startedAt: end.addingTimeInterval(-20), endedAt: end)
    }

    func testMigratesLegacyTitlesAndLabelsButPreservesLongTermUsage() throws {
        let url = directory.appendingPathComponent("phase0.sqlite")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        let old = instant.addingTimeInterval(-400 * 86400).timeIntervalSince1970
        try sql(db, """
            CREATE TABLE sessions (id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL,
            ended_at REAL NOT NULL, dwell_seconds REAL NOT NULL, bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL, window_title TEXT, label TEXT);
            INSERT INTO sessions VALUES(1, \(old), \(old + 20), 20, 'browser', 'Browser',
              'SECRET-TITLE-9191', 'SECRET-LABEL-8282');
            """)
        sqlite3_close(db)
        try "SECRET-EXPORT".write(to: directory.appendingPathComponent("phase0-export.csv"), atomically: true, encoding: .utf8)
        let store = try SessionStore(directory: directory, now: { self.instant })
        XCTAssertEqual(count(store, "sessions"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("phase0-export.csv").path))
        var stmt: OpaquePointer?
        XCTAssertNotEqual(sqlite3_prepare_v2(store.db, "SELECT window_title FROM sessions", -1, &stmt, nil), SQLITE_OK)
        sqlite3_finalize(stmt)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("SECRET-TITLE-9191".utf8)))
        XCTAssertNil(bytes.range(of: Data("SECRET-LABEL-8282".utf8)))
        XCTAssertTrue(store.historySummary().contains("Browser"))
    }

    func testNewRecordsAndExportsNeverStoreWindowTitles() throws {
        let store = try SessionStore(directory: directory, now: { self.instant })
        try store.record(session(title: "DO-NOT-PERSIST-123"), category: "doc")
        let export = try store.exportCSV()
        let text = try String(contentsOf: export)
        XCTAssertTrue(text.contains("doc"))
        XCTAssertFalse(text.contains("window_title"))
        XCTAssertFalse(text.contains("DO-NOT-PERSIST"))
        sqlite3_wal_checkpoint_v2(store.db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        XCTAssertNil(try Data(contentsOf: store.databaseURL).range(of: Data("DO-NOT-PERSIST-123".utf8)))
    }

    func testDeleteErasesOutcomesExportsAndMergeCache() throws {
        let store = try SessionStore(directory: directory, now: { self.instant })
        try store.record(session(), category: "doc")
        let id = store.recordFired(ruleID: "doc", category: "doc", at: instant)!
        store.updateOutcome(eventID: id, to: .dismissed)
        let export = try store.exportCSV()
        try store.deleteAll()
        XCTAssertEqual(count(store, "sessions"), 0)
        XCTAssertEqual(count(store, "rule_events"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        let returned = Session(context: session().context, startedAt: instant.addingTimeInterval(1), endedAt: instant.addingTimeInterval(10))
        try store.record(returned, category: "doc")
        XCTAssertEqual(count(store, "sessions"), 1)
    }

    func testOptInRetentionPrunesHistoryAndOutcomesAndExport() throws {
        let store = try SessionStore(directory: directory, now: { self.instant })
        try store.record(session(end: instant.addingTimeInterval(-100 * 86400)), category: "doc")
        try store.record(session(), category: "doc")
        store.recordFired(ruleID: "doc", category: "doc", at: instant.addingTimeInterval(-100 * 86400))
        store.recordFired(ruleID: "doc", category: "doc", at: instant)
        let export = try store.exportCSV()
        XCTAssertEqual(count(store, "sessions"), 2)
        store.retentionDays = 30
        try store.pruneHistory()
        XCTAssertEqual(count(store, "sessions"), 1)
        XCTAssertEqual(count(store, "rule_events"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }

    func testDefaultPreservesOldHistoryAcrossRestart() throws {
        do {
            let store = try SessionStore(directory: directory, now: { self.instant })
            try store.record(session(end: instant.addingTimeInterval(-800 * 86400)), category: "ai")
        }
        let reopened = try SessionStore(directory: directory, now: { self.instant })
        XCTAssertEqual(count(reopened, "sessions"), 1)
        XCTAssertTrue(reopened.historySummary().contains("Until you delete it"))
        XCTAssertTrue(reopened.historySummary().contains("ai"))
    }

    func testSurfaceTotalsAreExactInMemoryAndClearedByDelete() throws {
        // Use midday so a 20-second session doesn't straddle the day's boundary.
        let midday = Calendar.current.startOfDay(for: instant).addingTimeInterval(12 * 3600)
        let store = try SessionStore(directory: directory, now: { midday })
        try store.record(session(title: "Tool_% - Chrome", end: midday), category: nil)
        XCTAssertEqual(store.accumulatedSecondsToday(surface: "Tool_%"), 20)
        XCTAssertEqual(store.accumulatedSecondsToday(surface: "Tool_"), 0)
        let reopened = try SessionStore(directory: directory, now: { midday })
        XCTAssertEqual(reopened.accumulatedSecondsToday(surface: "Tool_%"), 0)
        try store.deleteAll()
        XCTAssertEqual(store.accumulatedSecondsToday(surface: "Tool_%"), 0)
    }

    func testCaptureRejectsMissingChangedAndAmbiguousTitles() {
        XCTAssertNil(WindowCapture.uniqueMatchIndex(titles: ["Another window"], requested: "Original"))
        XCTAssertNil(WindowCapture.uniqueMatchIndex(titles: ["Original", "Original"], requested: "Original"))
        XCTAssertNil(WindowCapture.uniqueMatchIndex(titles: [nil, "Original"], requested: nil))
        XCTAssertEqual(WindowCapture.uniqueMatchIndex(titles: ["Other", "Original"], requested: "Original"), 1)
    }
}
