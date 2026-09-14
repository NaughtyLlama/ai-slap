import AppKit

/// Decides whether to interrupt, and never writes anything down.
///
/// The version this replaces kept a SQLite log so an on-device personaliser could learn
/// which rules were working for you. That log is what dragged in retention settings,
/// exports, a delete-everything button and an argument about whether a window title is
/// personal data. It also turned out not to be load-bearing: every rule in the book
/// needs only what is true *right now* — how long you have sat here, when you last used
/// AI, how many times you have come back today. All of that lives in this object and
/// dies with the process.
///
/// So: fixed rules, conservative cooldowns, no learning, no history. If a rule is wrong
/// for you, the fix is to edit the rulebook, not to wait for the app to notice.
final class NudgeEngine {

    // MARK: - Settings, all of them the user's

    /// Time and preferences are injected so the gates can be tested without waiting
    /// four minutes or touching the real defaults.
    private let now: () -> Date
    private let defaults: UserDefaults
    /// Injected alongside the clock: the real one asks the window server what is
    /// frontmost, which makes any test of the other gates depend on whatever happens to
    /// be open on the machine running it.
    private let suppressionCheck: () -> Suppression.Verdict

    var isEnabled: Bool {
        get { defaults.object(forKey: "nudgesEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "nudgesEnabled") }
    }

    /// How many interruptions a day is too many. Deliberately low: this is a product
    /// that is wrong most of the time by its own measurement, and the cost of a bad
    /// nudge is much higher than the value of a good one.
    var dailyBudget: Int {
        get { max(1, defaults.object(forKey: "dailyBudget") as? Int ?? 6) }
        set { defaults.set(newValue, forKey: "dailyBudget") }
    }

    /// Nothing between these hours. Stored rather than in memory because waking up to a
    /// crab at 3am is the kind of thing you fix once.
    var quietHours: (start: Int, end: Int) = (22, 8)

    /// Set by the menu. Survives nothing — a snooze is about this afternoon.
    private(set) var snoozedUntil: Date?

    func snooze(minutes: Int) {
        snoozedUntil = now().addingTimeInterval(TimeInterval(minutes) * 60)
    }
    func cancelSnooze() { snoozedUntil = nil }

    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        if now() >= snoozedUntil { return false }
        return true
    }

    // MARK: - Everything below is memory only

    private var current: WindowContext?
    private var currentStart: Date?
    private var lastAIContextAt: Date?
    private var lastFired: [String: Date] = [:]
    private var firedToday = 0
    private var budgetDay: Date?
    /// Seconds spent on each surface today, derived from titles and never written down.
    private var surfaceSeconds: [String: TimeInterval] = [:]
    private var surfaceDay: Date?
    /// When each surface was visited, for the rules that count returns rather than dwell.
    private var visits: [String: [Date]] = [:]
    /// One nudge per thing. Being told twice about the same window is how a mascot
    /// stops being funny.
    private var interrupted: Set<String> = []
    private var pending: (target: Handoff.Target, ruleID: String)?

    let rules: [CompiledRule]
    let destinations: [AIDestination]
    private let aiBundleIDs: Set<String>
    private let aiTitlePatterns: [NSRegularExpression]
    private let browserBundleIDs: Set<String>
    let suppression: Suppression
    let handoff: Handoff

    var onNudge: ((_ copy: String, _ prompt: String, _ ruleID: String) -> Void)?
    var onHandoffResult: ((Handoff.Result) -> Void)?

    init(rulebook: Rulebook, handoff: Handoff,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         suppressionCheck: (() -> Suppression.Verdict)? = nil) {
        self.now = now
        self.defaults = defaults
        self.rules = rulebook.rules.map {
            CompiledRule(rule: $0, browserBundleIds: rulebook.browserBundleIds)
        }
        self.destinations = rulebook.destinations
        self.browserBundleIDs = Set(rulebook.browserBundleIds)
        self.suppression = Suppression(
            conferencingBundleIDs: rulebook.suppression.conferencingBundleIds
        )
        self.handoff = handoff
        let live = self.suppression
        self.suppressionCheck = suppressionCheck ?? { live.check() }

        // Every configured destination counts as an AI context, derived rather than
        // listed. A hand-maintained list drifts; the app you hand work *to* can never
        // be a place you are failing to use AI.
        var ids = Set(rulebook.aiContexts.bundleIds)
        ids.formUnion(rulebook.destinations.compactMap(\.bundleId))
        self.aiBundleIDs = ids
        self.aiTitlePatterns = rulebook.aiContexts.browserTitlePatterns
            .compactMap(CompiledRule.compile)
    }

    // MARK: - Watching

    func contextChanged(to context: WindowContext) {
        closeCurrent()
        current = context
        currentStart = now()
        interrupted.remove(signature(for: context))

        if isAIContext(context) { lastAIContextAt = now() }
        if let surface = context.surfaceKey {
            visits[surface, default: []].append(now())
            // Two hours is longer than any rule looks back.
            visits[surface] = visits[surface]?.filter { now().timeIntervalSince($0) < 7200 }
        }
    }

    func contextEnded() { closeCurrent(); current = nil; currentStart = nil }

    private func closeCurrent() {
        guard let context = current, let start = currentStart else { return }
        if isAIContext(context) { lastAIContextAt = now() }
        guard let surface = context.surfaceKey else { return }
        resetDayIfNeeded()
        surfaceSeconds[surface, default: 0] += now().timeIntervalSince(start)
    }

    func isAIContext(_ context: WindowContext) -> Bool {
        if aiBundleIDs.contains(context.bundleID) { return true }
        guard browserBundleIDs.contains(context.bundleID), let title = context.title
        else { return false }
        return aiTitlePatterns.contains { $0.matches(title) }
    }

    /// How close the current sit is to the best-matching rule's threshold, 0 to 1.
    /// Doug uses it to look up before anything is said, which is the cheapest
    /// interruption the product has.
    func dwellProgress() -> Double? {
        guard let context = current, let start = currentStart,
              let rule = bestRule(for: context),
              case .pass = gate(rule, context: context)
        else { return nil }
        let needed = rule.rule.condition.dwellMs / 1000
        guard needed > 0 else { return nil }
        return min(1, now().timeIntervalSince(start) / needed)
    }

    // MARK: - Deciding

    enum Gate {
        case pass
        case blocked(String)
    }

    func tick() {
        guard let context = current, let start = currentStart,
              let rule = bestRule(for: context) else { return }
        guard case .pass = gate(rule, context: context) else { return }
        guard now().timeIntervalSince(start) >= rule.rule.condition.dwellMs / 1000 else { return }
        fire(rule, context: context)
    }

    private func bestRule(for context: WindowContext) -> CompiledRule? {
        rules.filter { $0.matches(context) }
            .max { $0.rule.confidence < $1.rule.confidence }
    }

    func gate(_ candidate: CompiledRule, context: WindowContext) -> Gate {
        guard isEnabled else { return .blocked("nudges are off") }
        if isSnoozed, let until = snoozedUntil {
            return .blocked("snoozed until \(Self.clock.string(from: until))")
        }
        let verdict = suppressionCheck()
        if verdict.suppressed { return .blocked(verdict.reason ?? "suppressed") }

        let now = now()
        let hour = Calendar.current.component(.hour, from: now)
        let quiet = quietHours.start > quietHours.end
            ? (hour >= quietHours.start || hour < quietHours.end)
            : (hour >= quietHours.start && hour < quietHours.end)
        if quiet { return .blocked("quiet until \(quietHours.end):00") }

        resetDayIfNeeded()
        guard firedToday < dailyBudget else {
            return .blocked("that's \(firedToday) today, which is the limit")
        }

        let rule = candidate.rule
        // The amnesty that matters: you just used AI, so you are not failing to.
        let grace = rule.condition.noAiContextForMs / 1000
        if grace > 0, let lastAI = lastAIContextAt,
           now.timeIntervalSince(lastAI) < grace {
            return .blocked("you used AI recently")
        }
        if let last = lastFired[rule.id],
           now.timeIntervalSince(last) < rule.cooldownMs / 1000 {
            return .blocked("\(rule.id) is cooling down")
        }
        if interrupted.contains(signature(for: context)) {
            return .blocked("already said something about this one")
        }
        if let required = rule.condition.accumulatedTodayMs {
            guard let surface = context.surfaceKey else { return .blocked("no surface") }
            resetDayIfNeeded()
            let accumulated = surfaceSeconds[surface, default: 0]
                + (currentStart.map { now.timeIntervalSince($0) } ?? 0)
            guard accumulated >= required / 1000 else {
                return .blocked("not enough time on \(surface) yet")
            }
        }
        if let required = rule.condition.returnCount,
           let within = rule.condition.returnWithinMs {
            guard let surface = context.surfaceKey else { return .blocked("no surface") }
            let recent = (visits[surface] ?? []).filter {
                now.timeIntervalSince($0) < within / 1000
            }
            guard recent.count >= required else {
                return .blocked("only \(recent.count) returns to \(surface)")
            }
        }
        if let required = rule.condition.repeatCount,
           let within = rule.condition.repeatWithinMs {
            guard let surface = context.surfaceKey else { return .blocked("no surface") }
            let recent = (visits[surface] ?? []).filter {
                now.timeIntervalSince($0) < within / 1000
            }
            guard recent.count >= required else {
                return .blocked("only \(recent.count) of those")
            }
        }
        return .pass
    }

    // MARK: - Interrupting

    private func fire(_ candidate: CompiledRule, context: WindowContext) {
        resetDayIfNeeded()
        firedToday += 1
        lastFired[candidate.id] = now()
        interrupted.insert(signature(for: context))

        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            pending = (
                Handoff.Target(
                    pid: pid,
                    title: WindowCapture.focusedWindowTitle(pid: pid),
                    prompt: candidate.rule.nudge.promptTemplate
                ),
                candidate.id
            )
        }
        onNudge?(candidate.rule.nudge.copy, candidate.rule.nudge.promptTemplate, candidate.id)
    }

    /// The user said yes. Everything else about their answer is forgotten on purpose —
    /// there is nothing here that learns, so there is nothing to record it for.
    func accept() {
        guard let pending else { return }
        self.pending = nil
        handoff.run(pending.target) { [weak self] result in self?.onHandoffResult?(result) }
    }

    func decline() { pending = nil }

    /// Mute for the rest of the day rather than forever. A rule that annoyed you once
    /// on a Tuesday should not be silently dead in March.
    func muteForToday(_ ruleID: String) {
        lastFired[ruleID] = Calendar.current.startOfDay(for: now()).addingTimeInterval(86_400)
    }

    /// The user is already doing the thing. Start the amnesty clock.
    func markUsedAI() { lastAIContextAt = now() }

    // MARK: - Bookkeeping

    private func signature(for context: WindowContext) -> String {
        "\(context.bundleID)|\(context.title ?? "")"
    }

    private func resetDayIfNeeded() {
        let today = Calendar.current.startOfDay(for: now())
        if budgetDay != today { budgetDay = today; firedToday = 0 }
        if surfaceDay != today { surfaceDay = today; surfaceSeconds.removeAll() }
    }

    var firedTodayCount: Int { firedToday }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()
}
