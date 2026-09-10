import AppKit
import UserNotifications

/// Decides whether to interrupt, and delivers it.
///
/// Phase 1 replaces the delivery half with the mascot (docs/04). The gating half —
/// everything in `shouldFire` — is the part that keeps the product alive, and it is
/// written to survive that swap unchanged.
///
/// docs/03: an interruption fires only if *all* gates pass. The default is silence.
final class InterruptionEngine {

    enum Sensitivity: String, CaseIterable {
        case gentle, balanced, pushy

        /// Minimum adjusted confidence needed to fire.
        var threshold: Double {
            switch self {
            case .gentle:   return 0.70
            case .balanced: return 0.50
            case .pushy:    return 0.35
            }
        }

        var title: String {
            switch self {
            case .gentle:   return "Gentle"
            case .balanced: return "Balanced"
            case .pushy:    return "Pushy"
            }
        }
    }

    /// How long after touching an AI app nothing may fire.
    ///
    /// docs/02 sets this at 10 minutes and calls it fail-open: accusing someone of
    /// skipping AI right after they used it is the fastest uninstall available. That
    /// reasoning holds for someone who uses AI occasionally.
    ///
    /// It inverts for someone who works *inside* AI all day. Their pattern is to start
    /// something with AI, then move to another window while it runs — and that move is
    /// the exact moment worth catching. A blanket amnesty makes the product blind to
    /// its best trigger and silent for its most engaged users.
    ///
    /// So it is a setting rather than a constant. "I already did" stays on every nudge
    /// regardless, which keeps the fail-open escape hatch docs/02 actually depends on.
    enum Amnesty: String, CaseIterable {
        case off, brief, standard

        var title: String {
            switch self {
            case .off:      return "None — nudge me anyway"
            case .brief:    return "2 minutes"
            case .standard: return "10 minutes (default)"
            }
        }

        /// Seconds of silence after AI use. `ruleDefault` comes from the rulebook.
        func seconds(ruleDefault: TimeInterval) -> TimeInterval {
            switch self {
            case .off:      return 0
            case .brief:    return 120
            case .standard: return ruleDefault
            }
        }
    }

    /// docs/04 requires a mascot-free path: some people will hate the character,
    /// enterprise will demand it, and it is the headless route the rules engine already
    /// targets. Here it is the notification path, kept working rather than deleted.
    enum Style: String, CaseIterable {
        case panel, notification

        var title: String {
            switch self {
            case .panel:        return "Panel that waits for you"
            case .notification: return "System notification"
            }
        }
    }

    var style: Style {
        get {
            let raw = UserDefaults.standard.string(forKey: "style") ?? ""
            return Style(rawValue: raw) ?? .panel
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "style") }
    }

    let suppression: Suppression

    var amnesty: Amnesty {
        get {
            let raw = UserDefaults.standard.string(forKey: "amnesty") ?? ""
            return Amnesty(rawValue: raw) ?? .standard
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "amnesty") }
    }

    /// docs/03: hard cap, four a day. The single most important nag-fatigue control.
    var dailyBudget: Int {
        get { UserDefaults.standard.object(forKey: "dailyBudget") as? Int ?? 4 }
        set { UserDefaults.standard.set(newValue, forKey: "dailyBudget") }
    }

    /// Nothing fires outside these hours.
    var quietHours: (start: Int, end: Int) = (22, 8)

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "nudgesEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "nudgesEnabled") }
    }

    var sensitivity: Sensitivity {
        get {
            let raw = UserDefaults.standard.string(forKey: "sensitivity") ?? ""
            return Sensitivity(rawValue: raw) ?? .balanced
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sensitivity") }
    }

    let rules: [CompiledRule]
    private let rulebook: Rulebook
    private let store: SessionStore
    private let personalizer: Personalizer

    private let aiBundleIDs: Set<String>
    private let aiBrowserTitlePatterns: [NSRegularExpression]
    private let browserBundleIDs: Set<String>

    private var lastAIContextAt: Date?
    private var pendingTimers: [Timer] = []
    private var pendingEventIDs: [String: Int64] = [:]

    /// The window each pending nudge was about. Captured when the nudge fires, not
    /// when it is accepted: by accept time the frontmost app may well be something
    /// else, and handing over the wrong window is worse than handing over nothing.
    private var pendingTargets: [Int64: Handoff.Target] = [:]

    let handoff: Handoff

    /// Contexts already interrupted about, so the same email can't be nagged twice
    /// without an intervening AI use (docs/03). In memory only — it holds titles, and
    /// titles never reach disk outside the Phase 0 log.
    private var interruptedSignatures: Set<String> = []

    init(rulebook: Rulebook, store: SessionStore, personalizer: Personalizer) {
        self.rulebook = rulebook
        self.store = store
        self.personalizer = personalizer
        self.rules = rulebook.rules.map {
            CompiledRule(rule: $0, browserBundleIds: rulebook.browserBundleIds)
        }
        self.handoff = Handoff(destinations: rulebook.destinations)
        self.suppression = Suppression(
            conferencingBundleIDs: rulebook.suppression.conferencingBundleIds
        )
        // Every configured handoff destination counts as an AI context, on top of the
        // hand-maintained list.
        //
        // This is not a convenience — it closes the hole that produced the worst nudge
        // this product has fired. `ChatGPT.app` ships as `com.openai.codex`; the
        // rulebook asserted `com.openai.chat`, which is not installed on any machine
        // checked. So the app was invisible as an AI surface, and the first rule capable
        // of reaching it interrupted Chen *inside ChatGPT* to suggest he use AI.
        //
        // A hand-maintained bundle list will drift again — vendors rename, ship second
        // apps, fork. But **the app you hand work to can never be a place you are failing
        // to use AI**, so deriving these from the destinations makes that specific
        // absurdity structurally impossible rather than a list-maintenance problem.
        self.aiBundleIDs = Set(rulebook.aiContexts.bundleIds)
            .union(rulebook.destinations.compactMap(\.bundleId))
        self.aiBrowserTitlePatterns = rulebook.aiContexts.browserTitlePatterns
            .compactMap(CompiledRule.compile)
        self.browserBundleIDs = Set(rulebook.browserBundleIds)
    }

    // MARK: - Classification

    /// The category token a context reduces to, or nil if no rule claims it.
    func category(for context: WindowContext) -> String? {
        if isAIContext(context) { return "ai" }
        return rules.first { $0.matches(context) }?.category
    }

    func isAIContext(_ context: WindowContext) -> Bool {
        if aiBundleIDs.contains(context.bundleID) { return true }
        // Title patterns apply to browser tabs only. Anywhere else, a file or folder
        // named after a model would open a ten-minute amnesty and silence every rule
        // without the user ever seeing why.
        guard browserBundleIDs.contains(context.bundleID),
              let title = context.title
        else { return false }
        return aiBrowserTitlePatterns.contains { $0.matches(title) }
    }

    // MARK: - Context lifecycle

    /// Called on every context change. Schedules an evaluation for the moment this
    /// context would become interesting, rather than polling.
    func contextBegan(_ context: WindowContext, at start: Date) {
        contextEnded()

        if isAIContext(context) {
            // docs/02: any AI surface opens a grace window and clears the
            // already-interrupted set, because the user just did the thing.
            //
            // With the amnesty off, clearing that set would re-arm every context the
            // user already declined — and someone with the amnesty off passes through
            // AI constantly, so the same email would nag on every return trip.
            lastAIContextAt = Date()
            if amnesty != .off { interruptedSignatures.removeAll() }
            return
        }

        guard isEnabled else { return }

        for candidate in armedRules(for: context) {
            let threshold = personalizer.dwellThreshold(for: candidate.rule).seconds
            let fireAt = start.addingTimeInterval(threshold)
            let delay = max(fireAt.timeIntervalSinceNow, 0.5)

            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
                [weak self] _ in
                self?.evaluate(candidate, context: context, contextStart: start)
            }
            pendingTimers.append(timer)
        }
    }

    func contextEnded() {
        pendingTimers.forEach { $0.invalidate() }
        pendingTimers.removeAll()
    }

    /// Every rule that gets a clock on this context — normally one, sometimes two.
    ///
    /// One is the historical behaviour: the highest-confidence rule claiming the
    /// context wins, and the rest stay quiet so a single moment produces a single
    /// nudge.
    ///
    /// The exception is a rule keyed on *returns* rather than duration. Those measure
    /// something a dwell rule structurally cannot see, and by confidence alone they are
    /// shadowed precisely where they matter most: `email.message.dwell` claims every
    /// email at 0.80 confidence and then never fires, because a week of Chen's log has a
    /// longest single sit of 81 seconds against its 90-second bar. The dwell rule wins
    /// the context and produces nothing, forever, and the returns rule never gets asked.
    ///
    /// So a returns rule is armed alongside rather than instead. Both still pass through
    /// every gate, the cooldowns and the daily budget still bind, and the
    /// already-nudged-about-this set still stops the two of them doubling up on one
    /// surface.
    private func armedRules(for context: WindowContext) -> [CompiledRule] {
        var armed: [CompiledRule] = []
        if let best = bestRule(for: context) { armed.append(best) }

        if let returns = rules.first(where: {
            $0.rule.enabled && $0.rule.condition.returnCount != nil && $0.matches(context)
        }), !armed.contains(where: { $0.id == returns.id }) {
            armed.append(returns)
        }
        return armed
    }

    /// Highest-confidence rule claiming this context — or, if none do, the
    /// accumulation rule, which is defined precisely by what the others ignore.
    private func bestRule(for context: WindowContext) -> CompiledRule? {
        if let claimed = rules
            .filter({ $0.matches(context) })
            .max(by: { $0.rule.confidence < $1.rule.confidence })
        {
            return claimed
        }
        return unrecognisedRule(for: context)
    }

    private func unrecognisedRule(for context: WindowContext) -> CompiledRule? {
        guard context.surfaceKey != nil else { return nil }
        return rules.first {
            $0.rule.enabled
                && $0.rule.match.unrecognised
                && ($0.bundleIDs.isEmpty || $0.bundleIDs.contains(context.bundleID))
        }
    }

    // MARK: - The gates

    private func evaluate(
        _ candidate: CompiledRule, context: WindowContext, contextStart: Date
    ) {
        // Still here? The timer fired, but the user may have moved on in the meantime.
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier == context.bundleID
        else { return }

        guard let decision = shouldFire(candidate, context: context) else { return }
        fire(candidate, context: context, confidence: decision)
    }

    /// Why an interruption did or didn't happen.
    ///
    /// The gates return a *reason* rather than a bare nil because silence is this
    /// product's normal state, which makes "working perfectly" and "completely broken"
    /// look identical from the outside. The menu shows the reason, so a quiet day is
    /// legible instead of suspicious.
    enum Gate {
        case pass(confidence: Double)
        case blocked(String)
    }

    func gate(_ candidate: CompiledRule, context: WindowContext) -> Gate {
        guard isEnabled else { return .blocked("nudges are switched off") }

        // First, because docs/04 treats appearing during a screen share as the anecdote
        // that kills the company. Hiding needlessly costs nothing; failing to hide once
        // costs the account.
        let verdict = suppression.check()
        if verdict.suppressed {
            return .blocked(verdict.reason ?? "suppressed")
        }

        let rule = candidate.rule
        let now = Date()

        let hour = Calendar.current.component(.hour, from: now)
        let inQuietHours = quietHours.start > quietHours.end
            ? (hour >= quietHours.start || hour < quietHours.end)
            : (hour >= quietHours.start && hour < quietHours.end)
        if inQuietHours {
            return .blocked("quiet hours until \(quietHours.end):00")
        }

        let firedToday = store.firedToday()
        guard firedToday < dailyBudget else {
            return .blocked("daily budget spent (\(firedToday)/\(dailyBudget))")
        }

        // docs/02, fail open — subject to the user's amnesty setting above.
        let grace = amnesty.seconds(ruleDefault: rule.condition.noAiContextForMs / 1000)
        if grace > 0, let lastAI = lastAIContextAt {
            let elapsed = now.timeIntervalSince(lastAI)
            if elapsed < grace {
                return .blocked(
                    "used AI \(short(elapsed)) ago — quiet for another "
                    + "\(short(grace - elapsed))"
                )
            }
        }

        if let last = store.lastFired(ruleID: rule.id) {
            let cooldown = rule.cooldownMs / 1000
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cooldown {
                return .blocked("\(rule.id) cooling down for \(short(cooldown - elapsed))")
            }
        }

        let mute = personalizer.isMuted(rule.id)
        if mute.muted {
            return .blocked("\(rule.id) muted — \(mute.reason ?? "learned")")
        }

        let signature = "\(rule.id)|\(context.title ?? context.bundleID)"
        if interruptedSignatures.contains(signature) {
            return .blocked("already nudged about this one")
        }

        if let required = rule.condition.accumulatedTodayMs {
            guard let surface = context.surfaceKey else {
                return .blocked("no surface to total up")
            }
            let accumulated = store.accumulatedSecondsToday(surface: surface)
            guard accumulated >= required / 1000 else {
                return .blocked(String(
                    format: "%@ has taken %dm today, needs %dm",
                    surface,
                    Int(accumulated / 60),
                    Int(required / 60000)
                ))
            }
        }

        if let needed = rule.condition.returnCount,
           let window = rule.condition.returnWithinMs {
            guard let surface = context.surfaceKey else {
                return .blocked("no surface to count returns to")
            }
            let ceiling = (rule.condition.returnShorterThanMs ?? 120_000) / 1000
            let visits = store.visitCount(
                surface: surface, withinLast: window / 1000, upTo: ceiling
            )
            guard visits >= needed else {
                return .blocked(
                    "back to \(surface) \(visits)× in \(short(window / 1000)), needs \(needed)"
                )
            }
        }

        if let needed = rule.condition.repeatCount,
           let window = rule.condition.repeatWithinMs {
            let seen = store.sessionCount(
                category: rule.category, withinLast: window / 1000
            )
            guard seen >= needed else {
                return .blocked("needs \(needed) in \(short(window / 1000)), seen \(seen)")
            }
        }

        let adjusted = rule.confidence
            * personalizer.trustMultiplier(for: rule.id)
            * personalizer.receptivityMultiplier(at: now)
        guard adjusted >= sensitivity.threshold else {
            return .blocked(String(
                format: "confidence %.2f below %@ threshold %.2f",
                adjusted, sensitivity.title.lowercased(), sensitivity.threshold
            ))
        }

        return .pass(confidence: adjusted)
    }

    /// Returns the adjusted confidence if every gate passes, nil otherwise.
    func shouldFire(_ candidate: CompiledRule, context: WindowContext) -> Double? {
        if case .pass(let confidence) = gate(candidate, context: context) {
            return confidence
        }
        return nil
    }

    /// How far this context has travelled toward a nudge, 0…1, or nil if nothing is
    /// armed against it and nothing will fire.
    ///
    /// This exists for the mascot and for nothing else. docs/04 wants tier 1 — Doug
    /// stopping and looking at your window — to be the overwhelming majority of
    /// interruptions, which means it has to happen *before* the nudge rather than as
    /// part of it. Reading the same gates the fire path reads keeps the stare honest:
    /// he never looks up for something that is blocked and would never have arrived.
    func dwellProgress(for context: WindowContext?, since start: Date?) -> Double? {
        guard isEnabled, let context, let start, !isAIContext(context) else { return nil }
        guard let candidate = bestRule(for: context) else { return nil }
        guard case .pass = gate(candidate, context: context) else { return nil }

        let threshold = personalizer.dwellThreshold(for: candidate.rule).seconds
        guard threshold > 0 else { return 1 }
        return min(Date().timeIntervalSince(start) / threshold, 1)
    }

    /// One line explaining what the engine is doing about the current context.
    func statusLine(for context: WindowContext?, since start: Date?) -> String {
        guard isEnabled else { return "Nudges off" }
        guard let context else { return "Watching…" }

        if isAIContext(context) {
            return "In an AI app — nothing fires for 10 min after you leave"
        }
        guard let candidate = bestRule(for: context) else {
            return context.title == nil
                ? "No window title — can't classify this one"
                : "No rule watches this context"
        }

        switch gate(candidate, context: context) {
        case .blocked(let reason):
            return "Held: \(reason)"
        case .pass:
            let threshold = personalizer.dwellThreshold(for: candidate.rule).seconds
            let elapsed = start.map { Date().timeIntervalSince($0) } ?? 0
            let remaining = threshold - elapsed
            return remaining > 0
                ? "\(candidate.id) in \(short(remaining))"
                : "\(candidate.id) — firing"
        }
    }

    private func short(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? "\(Int(seconds.rounded()))s"
            : "\(Int((seconds / 60).rounded()))m"
    }

    // MARK: - Delivery

    private func fire(
        _ candidate: CompiledRule, context: WindowContext, confidence: Double
    ) {
        let rule = candidate.rule
        let signature = "\(rule.id)|\(context.title ?? context.bundleID)"
        interruptedSignatures.insert(signature)

        guard let eventID = store.recordFired(
            ruleID: rule.id, category: rule.category
        ) else { return }

        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            pendingTargets[eventID] = Handoff.Target(
                pid: pid, title: context.title, prompt: rule.nudge.promptTemplate
            )
        }

        if style == .panel, let onPresentPanel {
            var copy = rule.nudge.copy
            // Naming the surface here is safe: the panel is local and the string never
            // leaves the device. docs/05 forbids putting it in the *prompt*, which does
            // get transmitted, and that stays generic.
            if rule.condition.accumulatedTodayMs != nil, let surface = context.surfaceKey {
                let minutes = Int(store.accumulatedSecondsToday(surface: surface) / 60)
                copy = "\(surface) has eaten \(minutes) minutes today."
            } else if let window = rule.condition.returnWithinMs,
                      let surface = context.surfaceKey {
                // The count is the whole argument here — "you keep coming back" is a
                // claim, and a number is the difference between a claim and a receipt.
                let ceiling = (rule.condition.returnShorterThanMs ?? 120_000) / 1000
                let visits = store.visitCount(
                    surface: surface, withinLast: window / 1000, upTo: ceiling
                )
                copy = "That's \(visits) trips back to \(surface). Hand it over instead?"
            }
            onPresentPanel(copy, rule.nudge.promptTemplate, eventID, rule.id)
            onFire?()
            return
        }

        let identifier = "nudge.\(eventID)"
        pendingEventIDs[identifier] = eventID

        let content = UNMutableNotificationContent()
        content.title = rule.nudge.copy
        content.body = rule.nudge.promptTemplate
        content.categoryIdentifier = Self.notificationCategory
        content.sound = nil
        content.userInfo = ["eventID": eventID, "ruleID": rule.id]

        let request = UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("AISlap: notification failed — \(error.localizedDescription)")
            }
        }

        onFire?()
    }

    var onFire: (() -> Void)?

    /// Asks the app layer to show the panel: copy, prompt, event id, rule id.
    var onPresentPanel: ((String, String, Int64, String) -> Void)?

    /// Fires a real notification through the real delivery path, skipping every gate.
    /// Deliberately records nothing: a test must not pollute the acceptance history
    /// the Personaliser learns from.
    func sendTestNudge() {
        let content = UNMutableNotificationContent()
        content.title = "Test nudge — this is what one looks like"
        content.body = "Nothing was logged. Your real nudges use the same buttons."
        content.categoryIdentifier = Self.notificationCategory
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "nudge.test.\(UUID().uuidString)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            NSLog("AISlap: test notification failed — \(error.localizedDescription)")
        }
    }

    /// Whether notifications are actually permitted, so the menu can say so rather
    /// than leaving the user to infer it from silence.
    func notificationStatus(_ completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    // MARK: - Responses

    static let notificationCategory = "AISLAP_NUDGE"
    static let actionAccept = "AISLAP_ACCEPT"
    static let actionAlreadyDid = "AISLAP_ALREADY_DID"
    static let actionDismiss = "AISLAP_DISMISS"
    static let actionMute = "AISLAP_MUTE"

    static func registerNotificationCategory() {
        // No .foreground: activating AI-slap here would steal focus a moment before
        // the handoff opens the destination, and the paste would land in the wrong app.
        let accept = UNNotificationAction(
            identifier: actionAccept, title: "Hand it over", options: []
        )
        // docs/02: this is the only coverage for AI used on a phone or another
        // machine, and a high rate here is a detection bug, not user error.
        let alreadyDid = UNNotificationAction(
            identifier: actionAlreadyDid, title: "I already did", options: []
        )
        let dismiss = UNNotificationAction(
            identifier: actionDismiss, title: "Not now", options: []
        )
        let mute = UNNotificationAction(
            identifier: actionMute, title: "Stop suggesting this",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: notificationCategory,
            actions: [accept, alreadyDid, dismiss, mute],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func recordPanelOutcome(
        _ outcome: SessionStore.Outcome, eventID: Int64, ruleID: String? = nil
    ) {
        store.updateOutcome(eventID: eventID, to: outcome)
        if outcome == .muted, let ruleID {
            personalizer.setUserMuted(ruleID, muted: true)
        }
        if outcome == .accepted { runHandoff(for: eventID) }
        if outcome == .alreadyDid { lastAIContextAt = Date() }
    }

    func handleResponse(actionIdentifier: String, eventID: Int64, ruleID: String) {
        switch actionIdentifier {
        case Self.actionAccept, UNNotificationDefaultActionIdentifier:
            store.updateOutcome(eventID: eventID, to: .accepted)
            runHandoff(for: eventID)
        case Self.actionAlreadyDid:
            store.updateOutcome(eventID: eventID, to: .alreadyDid)
            lastAIContextAt = Date()
        case Self.actionMute:
            store.updateOutcome(eventID: eventID, to: .muted)
            personalizer.setUserMuted(ruleID, muted: true)
        case UNNotificationDismissActionIdentifier, Self.actionDismiss:
            store.updateOutcome(eventID: eventID, to: .dismissed)
        default:
            break
        }
    }

    /// Reports how a handoff went, so the UI can say "on your clipboard, press Cmd-V"
    /// instead of leaving the user staring at an empty composer.
    var onHandoffResult: ((Handoff.Result) -> Void)?

    private func runHandoff(for eventID: Int64) {
        guard let target = pendingTargets.removeValue(forKey: eventID) else { return }
        handoff.run(target) { [weak self] result in
            self?.onHandoffResult?(result)
        }
    }

    /// The hotkey path: no rule, no interruption, just whatever is in front right now.
    /// docs/05 calls this the "set a timer, screenshot it, drop it into Claude" quote
    /// made instant, and it is the entry point that works even when every rule is quiet.
    func handoffFrontmostWindow(title: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let target = Handoff.Target(
            pid: app.processIdentifier,
            title: title,
            prompt: "Here's what I'm working on — can you help me with this?"
        )
        handoff.run(target) { [weak self] result in
            self?.onHandoffResult?(result)
        }
    }

    func explanation() -> String {
        personalizer.explanation(for: rules)
    }

    struct RuleState {
        let id: String
        let userMuted: Bool
        let restingReason: String?
    }

    /// Every rule and whether it can currently fire, for the menu. A rule resting on a
    /// backoff is shown as resting, not as off: the distinction matters, because one
    /// comes back on its own and the other never does.
    func ruleStates() -> [RuleState] {
        let userMuted = personalizer.userMutedRules()
        return rules.filter { $0.rule.enabled }.map { compiled in
            let id = compiled.rule.id
            let muted = userMuted.contains(id)
            let resting = muted ? nil : personalizer.isMuted(id).reason
            return RuleState(id: id, userMuted: muted, restingReason: resting)
        }
    }

    func setUserMuted(_ ruleID: String, muted: Bool) {
        personalizer.setUserMuted(ruleID, muted: muted)
    }

    func resolveStaleEvents() {
        let resolved = store.resolveStaleEvents()
        if resolved > 0 {
            NSLog("AISlap: resolved \(resolved) unanswered nudge(s) as dismissed")
        }
    }
}
