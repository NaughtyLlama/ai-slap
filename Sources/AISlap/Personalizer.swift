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
            seconds: floored, isLearned: true, sampleCount: samples.count
        )
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

    /// docs/03: a rule whose acceptance sits below ~15% over a meaningful sample gets
    /// pulled. Remotely, that's an operational decision for everyone; here it's an
    /// automatic one for this person.
    func isMuted(_ ruleID: String) -> (muted: Bool, reason: String?) {
        let recent = store.recentOutcomes(ruleID: ruleID, limit: 3)
        if recent.count == 3 && recent.allSatisfy({ $0 == .dismissed }) {
            if let last = store.lastFired(ruleID: ruleID),
               Date().timeIntervalSince(last) < 86400 {
                return (true, "dismissed three times in a row — quiet for 24h")
            }
        }

        let tally = store.tally(ruleID: ruleID)
        if tally.resolved >= 12 {
            let rate = Double(tally.wins) / Double(tally.resolved)
            if rate < 0.15 {
                return (true, String(format: "only %.0f%% useful over %d — muted",
                                     rate * 100, tally.resolved))
            }
        }
        return (false, nil)
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
            if threshold.isLearned {
                line += " (learned from \(threshold.sampleCount) of your sessions; "
                line += "default \(format(rule.condition.dwellMs / 1000)))"
            } else {
                line += " (default — needs \(minimumDwellSamples - threshold.sampleCount) "
                line += "more sessions to adapt)"
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
