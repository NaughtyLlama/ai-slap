import Foundation
import SQLite3

/// Queries the Personaliser runs against local history. Everything here stays on the
/// device; docs/07 allows only anonymous counters to leave, and there is no network
/// code in this target to send them with.
extension SessionStore {

    // MARK: - Dwell history

    /// A glance is not work. Contexts shorter than this are a window stealing focus —
    /// a chat notification, a tab reloading — and there are hundreds of them.
    ///
    /// They were being fed into the dwell percentiles, which meant the "learned"
    /// threshold was computed partly from interruptions rather than from working. One
    /// notification tab alone contributed 249 sessions averaging 3.6 seconds.
    static let glanceThreshold: TimeInterval = 5

    /// Dwell times previously observed in a category, newest first, for learning what
    /// counts as a long sit *for this person*. Glances are excluded — see above.
    func dwellSamples(category: String, sinceDays: Int = 30, limit: Int = 400) -> [Double] {
        let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
            .timeIntervalSince1970
        let sql = """
            SELECT dwell_seconds FROM sessions
            WHERE category = ? AND started_at >= ?
              AND dwell_seconds >= \(Self.glanceThreshold)
            ORDER BY started_at DESC LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, category, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, cutoff)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var samples: [Double] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            samples.append(sqlite3_column_double(statement, 0))
        }
        return samples
    }

    /// How many sessions in a category started inside a recent window — the signal
    /// `search.repeated` triggers on.
    func sessionCount(category: String, withinLast interval: TimeInterval) -> Int {
        let cutoff = Date().addingTimeInterval(-interval).timeIntervalSince1970
        let sql = """
            SELECT COUNT(*) FROM sessions WHERE category = ? AND started_at >= ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, category, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, cutoff)

        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Interruption outcomes

    enum Outcome: String {
        case fired
        case accepted
        case alreadyDid = "already_did"
        case dismissed
        case snoozed
        case muted
    }

    @discardableResult
    func recordFired(ruleID: String, category: String, at date: Date = Date()) -> Int64? {
        let sql = """
            INSERT INTO rule_events (at, rule_id, category, outcome, hour)
            VALUES (?, ?, ?, 'fired', ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, ruleID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, category, -1, sqliteTransient)
        sqlite3_bind_int(statement, 4, Int32(Calendar.current.component(.hour, from: date)))

        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func updateOutcome(eventID: Int64, to outcome: Outcome) {
        let sql = "UPDATE rule_events SET outcome = ? WHERE id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, outcome.rawValue, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, eventID)
        _ = sqlite3_step(statement)
    }

    struct RuleTally {
        var fired = 0
        var accepted = 0
        var alreadyDid = 0
        var dismissed = 0
        var snoozed = 0

        /// Everything that resolved one way or the other. Interruptions still awaiting
        /// a response are excluded so an ignored notification doesn't read as a
        /// rejection the moment it appears.
        var resolved: Int { accepted + alreadyDid + dismissed + snoozed }

        /// `already_did` counts as a win: the user did use AI, we just couldn't see it
        /// (docs/02, fail open).
        var wins: Int { accepted + alreadyDid }
    }

    func tally(ruleID: String? = nil, sinceDays: Int = 60) -> RuleTally {
        let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
            .timeIntervalSince1970
        var sql = "SELECT outcome, COUNT(*) FROM rule_events WHERE at >= ?"
        if ruleID != nil { sql += " AND rule_id = ?" }
        sql += " GROUP BY outcome;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return RuleTally()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff)
        if let ruleID {
            sqlite3_bind_text(statement, 2, ruleID, -1, sqliteTransient)
        }

        var tally = RuleTally()
        while sqlite3_step(statement) == SQLITE_ROW {
            let outcome = String(cString: sqlite3_column_text(statement, 0))
            let count = Int(sqlite3_column_int64(statement, 1))
            tally.fired += count
            switch Outcome(rawValue: outcome) {
            case .accepted:   tally.accepted += count
            case .alreadyDid: tally.alreadyDid += count
            case .dismissed:  tally.dismissed += count
            case .snoozed:    tally.snoozed += count
            default:          break
            }
        }
        return tally
    }

    /// Most recent resolved outcomes for a rule, newest first — feeds the
    /// consecutive-dismissal backoff in docs/03.
    func recentOutcomes(ruleID: String, limit: Int = 5) -> [Outcome] {
        let sql = """
            SELECT outcome FROM rule_events
            WHERE rule_id = ? AND outcome != 'fired'
            ORDER BY at DESC LIMIT ?;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ruleID, -1, sqliteTransient)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var outcomes: [Outcome] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let outcome = Outcome(rawValue: String(cString: sqlite3_column_text(statement, 0))) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Resolved outcomes bucketed by hour of day — how receptive this person is at
    /// this time of day.
    func hourTally(hour: Int, sinceDays: Int = 60) -> RuleTally {
        let cutoff = Date().addingTimeInterval(-Double(sinceDays) * 86400)
            .timeIntervalSince1970
        let sql = """
            SELECT outcome, COUNT(*) FROM rule_events
            WHERE at >= ? AND hour = ? GROUP BY outcome;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return RuleTally()
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff)
        sqlite3_bind_int(statement, 2, Int32(hour))

        var tally = RuleTally()
        while sqlite3_step(statement) == SQLITE_ROW {
            let outcome = String(cString: sqlite3_column_text(statement, 0))
            let count = Int(sqlite3_column_int64(statement, 1))
            tally.fired += count
            switch Outcome(rawValue: outcome) {
            case .accepted:   tally.accepted += count
            case .alreadyDid: tally.alreadyDid += count
            case .dismissed:  tally.dismissed += count
            case .snoozed:    tally.snoozed += count
            default:          break
            }
        }
        return tally
    }

    /// An interruption nobody answered is a soft no, not an absence of one. Left as
    /// "fired" it silently inflates the acceptance denominator — the north-star metric
    /// — and never reaches the backoff. Resolved on launch for anything old enough
    /// that a reply is not coming.
    @discardableResult
    func resolveStaleEvents(olderThan interval: TimeInterval = 3600) -> Int {
        let cutoff = Date().addingTimeInterval(-interval).timeIntervalSince1970
        let sql = "UPDATE rule_events SET outcome = 'dismissed' WHERE outcome = 'fired' AND at < ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Seconds spent today in one unrecognised browser surface, keyed on the leading
    /// segment of the window title — "Termly - Part of group…" and "Termly - Google
    /// Chrome" are the same surface. Feeds the accumulation rule.
    func accumulatedSecondsToday(surface: String) -> TimeInterval {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let sql = """
            SELECT SUM(dwell_seconds) FROM sessions
            WHERE category IS NULL AND started_at >= ?
              AND window_title IS NOT NULL
              AND (window_title = ? OR window_title LIKE ? || ' - %');
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, startOfDay)
        sqlite3_bind_text(statement, 2, surface, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, surface, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else { return 0 }
        return sqlite3_column_double(statement, 0)
    }

    func firedToday() -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let sql = "SELECT COUNT(*) FROM rule_events WHERE at >= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, startOfDay)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func lastFired(ruleID: String) -> Date? {
        let sql = "SELECT MAX(at) FROM rule_events WHERE rule_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, ruleID, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL
        else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
    }
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
