import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

/// Local-only log of observed contexts.
///
/// ⚠️ Phase 0 stores **raw window titles on disk**. Shipping builds must not — see
/// docs/02, "Title handling": a title is reduced to a category token within the tick
/// and the raw string discarded. The spike is the deliberate exception, because the
/// whole point of Phase 0 is hand-labelling real titles to measure rule precision.
/// This file is where that exception lives; delete it, don't extend it, when the
/// rules engine lands.
///
/// Nothing here talks to the network. There is no network code in this target at all.
final class SessionStore {

    /// Contexts shorter than this are flicker — alt-tabbing through windows, a
    /// launcher taking focus for an instant. They are noise in a dwell-time study.
    static let minimumDwell: TimeInterval = 2.0

    /// If you return to the context you just left within this window, it was one sit,
    /// not two. Dropping a sub-`minimumDwell` flicker in the middle of a sit would
    /// otherwise split it — and dwell is the signal every rule triggers on, so a
    /// 90-second email splitting into 40 + 24 silently loses the trigger.
    static let mergeWindow: TimeInterval = 5.0

    var db: OpaquePointer?
    let databaseURL: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AISlap", isDirectory: true)

        try FileManager.default.createDirectory(
            at: support, withIntermediateDirectories: true
        )
        databaseURL = support.appendingPathComponent("phase0.sqlite")

        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw StoreError.open(message: lastErrorMessage)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("""
            CREATE TABLE IF NOT EXISTS sessions (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                started_at    REAL NOT NULL,
                ended_at      REAL NOT NULL,
                dwell_seconds REAL NOT NULL,
                bundle_id     TEXT NOT NULL,
                app_name      TEXT NOT NULL,
                window_title  TEXT,
                label         TEXT
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS sessions_started_at
                ON sessions(started_at);
            """)

        // Added with the rules engine. Existing spike databases predate it, so this
        // is additive and failure here is not fatal.
        if !columnExists(table: "sessions", column: "category") {
            try? execute("ALTER TABLE sessions ADD COLUMN category TEXT;")
        }

        // One row per interruption. `outcome` starts as "fired" and is updated when
        // the user responds, so acceptance is accepted ÷ fired by construction —
        // the north star in docs/03, and deliberately not "interruptions fired".
        try execute("""
            CREATE TABLE IF NOT EXISTS rule_events (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                at       REAL NOT NULL,
                rule_id  TEXT NOT NULL,
                category TEXT,
                outcome  TEXT NOT NULL,
                hour     INTEGER NOT NULL
            );
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS rule_events_rule ON rule_events(rule_id, at);
            """)
    }

    private func columnExists(table: String, column: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "PRAGMA table_info(\(table));", -1, &statement, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == column { return true }
        }
        return false
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Writing

    /// The last row written, so a return to the same context within `mergeWindow`
    /// extends it instead of starting a second row.
    private struct LastWrite {
        let rowID: Int64
        let context: WindowContext
        let startedAt: Date
        var endedAt: Date
    }
    private var lastWrite: LastWrite?

    /// Result of offering a finished session to the log.
    enum RecordOutcome {
        /// Written as a new row.
        case inserted
        /// Folded into the row that came immediately before it — same context,
        /// returned to within `mergeWindow`.
        case merged
        /// Below `minimumDwell` and not a return to the previous context: flicker.
        case dropped
    }

    @discardableResult
    func record(_ session: Session, category: String?) throws -> RecordOutcome {
        // A return to the context we just left, with only a flicker in between.
        if var last = lastWrite,
           last.context == session.context,
           session.startedAt.timeIntervalSince(last.endedAt) <= Self.mergeWindow
        {
            last.endedAt = session.endedAt
            lastWrite = last
            try extendRow(
                id: last.rowID, startedAt: last.startedAt, endedAt: last.endedAt
            )
            return .merged
        }

        guard session.dwell >= Self.minimumDwell else { return .dropped }

        let sql = """
            INSERT INTO sessions
                (started_at, ended_at, dwell_seconds, bundle_id, app_name,
                 window_title, category)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.write(message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, session.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, session.endedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, session.dwell)
        bindText(statement, 4, session.context.bundleID)
        bindText(statement, 5, session.context.appName)
        if let title = session.context.title {
            bindText(statement, 6, title)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if let category {
            bindText(statement, 7, category)
        } else {
            sqlite3_bind_null(statement, 7)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.write(message: lastErrorMessage)
        }

        lastWrite = LastWrite(
            rowID: sqlite3_last_insert_rowid(db),
            context: session.context,
            startedAt: session.startedAt,
            endedAt: session.endedAt
        )
        return .inserted
    }

    private func extendRow(id: Int64, startedAt: Date, endedAt: Date) throws {
        let sql = """
            UPDATE sessions SET ended_at = ?, dwell_seconds = ? WHERE id = ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.write(message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, endedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, endedAt.timeIntervalSince(startedAt))
        sqlite3_bind_int64(statement, 3, id)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.write(message: lastErrorMessage)
        }
    }

    // MARK: - Reading

    struct Stats {
        var sessionCount: Int = 0
        var titledCount: Int = 0
        var totalDwell: TimeInterval = 0

        /// The Phase 0 headline number: what fraction of observed contexts gave us a
        /// window title at all. A low value means the Accessibility permission is
        /// missing or the app population is AX-hostile.
        var titleCoverage: Double {
            sessionCount == 0 ? 0 : Double(titledCount) / Double(sessionCount)
        }
    }

    func statsSinceStartOfDay() -> Stats {
        let startOfDay = Calendar.current.startOfDay(for: Date())
            .timeIntervalSince1970
        let sql = """
            SELECT COUNT(*),
                   SUM(CASE WHEN window_title IS NOT NULL THEN 1 ELSE 0 END),
                   SUM(dwell_seconds)
            FROM sessions WHERE started_at >= ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return Stats()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, startOfDay)

        var stats = Stats()
        if sqlite3_step(statement) == SQLITE_ROW {
            stats.sessionCount = Int(sqlite3_column_int64(statement, 0))
            stats.titledCount = Int(sqlite3_column_int64(statement, 1))
            stats.totalDwell = sqlite3_column_double(statement, 2)
        }
        return stats
    }

    /// Writes a CSV alongside the database, ready for hand-labelling in a spreadsheet.
    func exportCSV() throws -> URL {
        let url = databaseURL
            .deletingLastPathComponent()
            .appendingPathComponent("phase0-export.csv")

        // Fold the write-ahead log into the database file first. Without this the
        // .sqlite is a near-empty shell and the data lives in a sibling -wal file —
        // copy the database alone and you appear to have lost everything.
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)

        var csv = "started_at,dwell_seconds,bundle_id,app_name,category,window_title,label\n"
        let sql = """
            SELECT started_at, dwell_seconds, bundle_id, app_name, category,
                   window_title, label
            FROM sessions ORDER BY started_at;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.read(message: lastErrorMessage)
        }
        defer { sqlite3_finalize(statement) }

        let formatter = ISO8601DateFormatter()
        while sqlite3_step(statement) == SQLITE_ROW {
            let started = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let dwell = sqlite3_column_double(statement, 1)
            let fields = [
                formatter.string(from: started),
                String(format: "%.1f", dwell),
                columnText(statement, 2) ?? "",
                columnText(statement, 3) ?? "",
                columnText(statement, 4) ?? "",
                columnText(statement, 5) ?? "",
                columnText(statement, 6) ?? "",
            ]
            csv += fields.map(csvEscaped).joined(separator: ",") + "\n"
        }

        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func deleteAll() throws {
        try execute("DELETE FROM sessions;")
        try execute("VACUUM;")
    }

    // MARK: - Plumbing

    enum StoreError: LocalizedError {
        case open(message: String)
        case write(message: String)
        case read(message: String)

        var errorDescription: String? {
            switch self {
            case .open(let m):  return "Could not open the log database: \(m)"
            case .write(let m): return "Could not write to the log: \(m)"
            case .read(let m):  return "Could not read the log: \(m)"
            }
        }
    }

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.write(message: lastErrorMessage)
        }
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func csvEscaped(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
