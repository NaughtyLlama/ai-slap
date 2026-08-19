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

    /// docs/03: hard cap, four a day. The single most important nag-fatigue control.
    var dailyBudget = 4

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
    private var pendingTimer: Timer?
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
        self.aiBundleIDs = Set(rulebook.aiContexts.bundleIds)
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
        pendingTimer?.invalidate()
        pendingTimer = nil

        if isAIContext(context) {
            // docs/02: any AI surface opens a grace window and clears the
            // already-interrupted set, because the user just did the thing.
            lastAIContextAt = Date()
            interruptedSignatures.removeAll()
            return
        }

        guard isEnabled else { return }
        guard let candidate = bestRule(for: context) else { return }

        let threshold = personalizer.dwellThreshold(for: candidate.rule).seconds
        let fireAt = start.addingTimeInterval(threshold)
        let delay = max(fireAt.timeIntervalSinceNow, 0.5)

        pendingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) {
            [weak self] _ in
            self?.evaluate(candidate, context: context, contextStart: start)
        }
    }

    func contextEnded() {
        pendingTimer?.invalidate()
        pendingTimer = nil
    }

    /// Highest-confidence rule claiming this context.
    private func bestRule(for context: WindowContext) -> CompiledRule? {
        rules
            .filter { $0.matches(context) }
            .max { $0.rule.confidence < $1.rule.confidence }
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

        // docs/02, fail open. Telling someone they skipped AI right after they used it
        // is the fastest uninstall available.
        if let lastAI = lastAIContextAt {
            let grace = rule.condition.noAiContextForMs / 1000
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
}
