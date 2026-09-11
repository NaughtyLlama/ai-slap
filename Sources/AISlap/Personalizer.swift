import Foundation

/// Learns one person's habits and bends the generic rulebook to fit them.
///
/// The split matters. The rulebook says *what a context is* — "this title is one open
/// email" — and is the same for everybody, which is what lets it become a shared,
/// signed, remotely-updatable artifact (docs/03). This class says *what is unusual for
/// you*, and never leaves the device.
///
/// Three things adapt, in rough order of how much they matter:
///
/// 1. **Dwell thresholds.** A fixed 90-second email rule is wrong for almost everyone.
///    Someone who clears a mailbox in 20-second bursts would never trip it — the
///    product would sit silent and look broken. Someone who lives in 6-minute threads
///    would get pestered constantly. So the threshold becomes a high percentile of
///    *your own* dwell times in that category: long compared to how you normally work,
///    not compared to a number in a config file.
///
/// 2. **Per-rule trust.** Rules you keep accepting get more confident; rules you keep
///    dismissing get less, and eventually mute themselves. docs/03 pulls bad rules
///    remotely across the whole population; this does the same job per person, which
///    also catches rules that are fine in general and wrong for you specifically.
///
/// 3. **Time of day.** If you never accept anything before 10am, stop asking before
///    10am.
///
/// Everything is shrunk toward the rulebook default until there's enough evidence, so
/// a first run behaves exactly as specced and drifts from there. Adaptation can shorten
/// a threshold well below the rulebook value — that is the whole point for someone who
/// works in short bursts — bounded only by an absolute floor, and the daily budget and
/// cooldowns still cap how often anything actually fires.
final class Personalizer {

    private let store: SessionStore

    /// Below this many samples, use the rulebook value unchanged. Small enough to
    /// adapt within a day or two of real use, large enough not to swing on noise.
    private let minimumDwellSamples = 12

    /// Below this many resolved interruptions, a rule keeps its rulebook confidence.
    private let minimumOutcomeSamples = 6

    /// "Long for you" — the percentile of your own dwell distribution that counts as
    /// a long sit. p85 means roughly the top one sit in seven.
    private let dwellPercentile = 0.85

    /// Learned thresholds may not exceed this multiple of the rulebook value, so an
    /// unusual week can't push a rule out to never firing.
    ///
    /// There is deliberately **no matching lower multiple**. There was — 0.4× — and it
    /// was wrong in a way that defeated the entire class: it clamped learned thresholds
    /// *upward*, away from the user. Someone whose real sits average 17 seconds had a
    /// 19-second learned threshold dragged back to 48, so nothing ever fired and the
    /// adaptation layer might as well not have existed. Fast workers are exactly who
    /// personalisation is for. The absolute floor below is the only lower bound needed.
    private let thresholdCeilingMultiple = 2.5

    /// Nothing counts as parked in less time than this, whatever the maths say.
    /// Glancing at a window is not deliberation.
    private let absoluteFloor: TimeInterval = 20

    /// Beta prior on "will this person accept this rule". Mean 0.4, weak enough to be
    /// overwhelmed by a couple of dozen real outcomes.
    private let priorWins = 2.0
    private let priorLosses = 3.0

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: - 1. Dwell

    struct LearnedThreshold {
        let seconds: TimeInterval
        let isLearned: Bool
        let sampleCount: Int
        /// True when the personal figure came out under the absolute floor and the
        /// floor is what is actually being used. Reporting this as "learned" was a
        /// small lie the menu used to tell.
        var isFloored = false
        /// The personal figure before flooring, for the fit check below.
        var personalSeconds: TimeInterval = 0
    }

    /// How long you have to sit in this context before it counts as parked.
    func dwellThreshold(for rule: Rulebook.Rule) -> LearnedThreshold {
        let base = rule.condition.dwellMs / 1000
        let samples = store.dwellSamples(category: rule.category)

        guard samples.count >= minimumDwellSamples else {
            return LearnedThreshold(
                seconds: base, isLearned: false, sampleCount: samples.count
            )
        }

        let personal = percentile(samples, dwellPercentile)
        let bounded = min(personal, base * thresholdCeilingMultiple)
        let floored = max(bounded, absoluteFloor)

        return LearnedThreshold(
            seconds: floored,
            isLearned: true,
            sampleCount: samples.count,
            isFloored: bounded < absoluteFloor,
            personalSeconds: personal
        )
    }

    /// Whether a rule's premise describes this person at all.
    ///
    /// A rule saying "ninety seconds on one email" assumes lingering. If someone's own
    /// p85 is ten seconds, they never linger there — and no threshold fixes that,
    /// because there is nothing to find. The old behaviour silently used the floor and
    /// nagged them anyway, which is exactly how a rule ends up 0-for-5.
    ///
    /// This only ever *suggests*. Nothing is switched off without the user saying so.
    func fitsPoorly(_ rule: Rulebook.Rule) -> (poor: Bool, reason: String?) {
        let threshold = dwellThreshold(for: rule)
        guard threshold.isLearned, threshold.isFloored else { return (false, nil) }
        guard threshold.personalSeconds < absoluteFloor / 2 else { return (false, nil) }

        let seconds = Int(threshold.personalSeconds.rounded())
        return (true, "you rarely spend more than \(seconds)s here, so this rule's "
                    + "premise doesn't really describe how you work")
    }

    // MARK: - 2. Per-rule trust

    /// Multiplies the rule's rulebook confidence. Above 1 for rules you take up,
    /// below 1 for rules you brush off.
    func trustMultiplier(for ruleID: String) -> Double {
        let tally = store.tally(ruleID: ruleID)
        guard tally.resolved >= minimumOutcomeSamples else { return 1.0 }

        let posterior = (Double(tally.wins) + priorWins)
            / (Double(tally.resolved) + priorWins + priorLosses)
        let priorMean = priorWins / (priorWins + priorLosses)
        return clamp(posterior / priorMean, 0.4, 1.6)
    }

    /// How long a rule goes quiet after being turned down, by how many times running.
    ///
    /// The previous version was a flat 24 hours with no escalation, so a rule rejected
    /// five times out of five came back every single day — the nag-fatigue spiral
    /// docs/03 names as the most likely way this product dies.
    ///
    /// **Nothing here is permanent.** Even the longest backoff expires and the rule
    /// gets another chance, because what someone works on changes and a rule that was
    /// useless in August may fit in October. Only the user retires a rule for good, by
    /// asking for it — and that is reversible from the menu.
    private func backoffDuration(consecutiveDismissals streak: Int) -> TimeInterval? {
        switch streak {
        case 0..<3: return nil
        case 3..<5: return 86400          // a day
        case 5..<8: return 7 * 86400      // a week
        default:    return 14 * 86400     // a fortnight, then try again
        }
    }

    /// Rules the user explicitly retired with "Stop suggesting this". The only mute
    /// that does not expire — and it is listed in the menu, never silent.
    func resetHistoryPreferences() {
        UserDefaults.standard.removeObject(forKey: "userMutedRules")
    }

    func userMutedRules() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "userMutedRules") ?? [])
    }

    func setUserMuted(_ ruleID: String, muted: Bool) {
        var rules = userMutedRules()
        if muted { rules.insert(ruleID) } else { rules.remove(ruleID) }
        UserDefaults.standard.set(Array(rules), forKey: "userMutedRules")
    }

    func isMuted(_ ruleID: String) -> (muted: Bool, reason: String?) {
        if userMutedRules().contains(ruleID) {
            return (true, "you turned this one off")
        }

        let streak = consecutiveDismissals(ruleID)
        if let duration = backoffDuration(consecutiveDismissals: streak),
           let last = store.lastFired(ruleID: ruleID)
        {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < duration {
                return (true,
                        "turned down \(streak)x running — back in \(humanised(duration - elapsed))")
            }
        }

        // docs/03 pulls a rule below ~15% acceptance. Remotely that is an operational
        // decision for the whole population; here it is a local one for this person —
        // and unlike the remote pull, it lapses instead of sticking.
        let tally = store.tally(ruleID: ruleID)
        if tally.resolved >= 12 {
            let rate = Double(tally.wins) / Double(tally.resolved)
            if rate < 0.15, let last = store.lastFired(ruleID: ruleID) {
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < 14 * 86400 {
                    let pct = Int((rate * 100).rounded())
                    return (true,
                            "\(pct)% useful over \(tally.resolved) — resting for \(humanised(14 * 86400 - elapsed))")
                }
            }
        }
        return (false, nil)
    }

    /// Dismissals in a row, most recent first, stopping at the first non-dismissal.
    /// How many refusals in a row, counting an unanswered panel as half of one.
    ///
    /// docs/03 wants dismissals feeding the backoff rather than accumulating as
    /// silence, and that intent survives here — but only once the two are told apart.
    /// A rule nobody ever answers should still go quiet eventually; it should just take
    /// twice as much of it, because being ignored while typing is not the same as being
    /// turned down.
    private func consecutiveDismissals(_ ruleID: String) -> Int {
        var weight = 0.0
        for outcome in store.recentOutcomes(ruleID: ruleID, limit: 12) {
            switch outcome {
            case .dismissed: weight += 1
            case .ignored:   weight += 0.5
            default:         return Int(weight)
            }
        }
        return Int(weight)
    }

    private func humanised(_ interval: TimeInterval) -> String {
        let days = Int((interval / 86400).rounded(.up))
        if days <= 1 { return "a day" }
        if days <= 7 { return "\(days) days" }
        return "\(days / 7) weeks"
    }

    // MARK: - 3. Time of day

    func receptivityMultiplier(at date: Date = Date()) -> Double {
        let hour = Calendar.current.component(.hour, from: date)
        let hourTally = store.hourTally(hour: hour)
        guard hourTally.resolved >= 8 else { return 1.0 }

        let overall = store.tally()
        guard overall.resolved >= 20 else { return 1.0 }

        let hourRate = Double(hourTally.wins) / Double(hourTally.resolved)
        let overallRate = max(Double(overall.wins) / Double(overall.resolved), 0.05)
        return clamp(hourRate / overallRate, 0.5, 1.3)
    }

    // MARK: - Explaining itself

    /// What the app has learned, in plain language. A system that quietly changes its
    /// own behaviour needs to be able to show its work, or the first surprising
    /// silence reads as a bug.
    func explanation(for rules: [CompiledRule]) -> String {
        var lines: [String] = []
        let overall = store.tally()

        if overall.resolved == 0 {
            lines.append("No nudges answered yet, so everything is still running on "
                         + "the rulebook defaults. It starts adapting after a few.")
        } else {
            let rate = Double(overall.wins) / Double(overall.resolved) * 100
            lines.append(String(
                format: "Overall: %d nudges, %.0f%% useful.", overall.resolved, rate
            ))
        }
        lines.append("")

        for compiled in rules where compiled.rule.enabled {
            let rule = compiled.rule
            let threshold = dwellThreshold(for: rule)
            let tally = store.tally(ruleID: rule.id)
            let muted = isMuted(rule.id)

            var line = "• \(rule.id): fires after "
            line += format(threshold.seconds)
            if threshold.isFloored {
                // Say what is actually happening. Claiming this was "learned from 173
                // sessions" when the learned figure was discarded for the floor is a
                // small lie, and it hid the far more useful fact below.
                line += " (the minimum — your own figure is "
                line += "\(format(threshold.personalSeconds)), below it)"
            } else if threshold.isLearned {
                line += " (learned from \(threshold.sampleCount) of your sessions; "
                line += "default \(format(rule.condition.dwellMs / 1000)))"
            } else {
                line += " (default — needs \(minimumDwellSamples - threshold.sampleCount) "
                line += "more sessions to adapt)"
            }
            let fit = fitsPoorly(rule)
            if fit.poor, let reason = fit.reason {
                line += "\n   POOR FIT: \(reason)."
                line += " Turn it off from “Rules” if you agree."
            }
            if tally.resolved > 0 {
                line += "\n   \(tally.wins)/\(tally.resolved) useful"
                let trust = trustMultiplier(for: rule.id)
                if abs(trust - 1.0) > 0.01 {
                    line += String(format: ", confidence ×%.2f", trust)
                }
            }
            if muted.muted, let reason = muted.reason {
                line += "\n   MUTED: \(reason)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Maths

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }

    private func format(_ seconds: TimeInterval) -> String {
        seconds < 90
            ? "\(Int(seconds.rounded()))s"
            : String(format: "%.1fm", seconds / 60)
    }
}
