# 03 — Rules & nudges

The rules engine turns raw signals into a decision: *should we interrupt, how confident
are we, and how hard should it land?* The mascot layer ([04](04-mascot-and-interruptions.md))
decides what the interruption looks like.

## The rulebook is remote, signed, and versioned

**Never hardcode site patterns into the binary.** If Gmail changes its title format and
the fix requires an app release, that's a code change, a notarization round, and a Sparkle
rollout that reaches maybe 60% of users in a week. The same fix as a rulebook push reaches
everyone in six hours.

This is the single most important scaling decision in the client.

- Static JSON on a CDN, ETag'd, polled every 6 hours and on wake.
- **Ed25519-signed**, verified before load. A rulebook that can inject prompt templates and
  destination URLs is a remote-code-execution surface if unsigned — treat it as such.
- Client pins a minimum schema version and ignores rules it doesn't understand, so old
  clients degrade instead of breaking.
- Ships with a baked-in default rulebook so a first run with no network still works.

## Rule schema

```jsonc
{
  "id": "gmail.single-message.dwell",
  "schemaVersion": 1,
  "match": {
    "bundleId": ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"],
    "titlePattern": "^(?!Inbox)(.+) - .+@.+ - Gmail$",
    "locales": { "fr": "^(?!Boîte de réception)(.+) - .+@.+ - Gmail$" }
  },
  "condition": {
    "dwellMs": 90000,
    "noAiContextForMs": 600000
  },
  "confidence": 0.8,
  "cooldownMs": 3600000,
  "maxTier": 2,
  "nudge": {
    "copy": "You're really going to type that whole reply yourself?",
    "promptTemplate": "Here's an email I need to reply to. Draft a concise, friendly reply in my voice.",
    "destination": "default"
  }
}
```

`match.origin` is reserved in the schema for the Phase 3 enterprise extension and unused
in v1.

## Starter rule set

All reachable from bundle ID + title + dwell alone — no page access required.

| Rule | Trigger | Prompt seed |
|---|---|---|
| `gmail.single-message.dwell` | One message open >90s | "Draft a reply to this email" |
| `slack.channel.dwell` | Slack frontmost >2min, no AI in 10min | "Draft a response to this thread" |
| `doc.blank.dwell` | Docs/Notion, untitled or empty, >60s | "Help me outline this document" |
| `sheet.dwell` | Sheets/Excel frontmost >3min | "Help me with this spreadsheet" |
| `search.repeated` | 3+ Google searches on one topic in 10min | "Answer this properly instead" |
| `task.recurring` | Same context signature 3+ times this week | "You do this every week — automate it" |
| `timer.checkin` | Scheduled interval, any context | "Whatever you're doing — send it here" |

**`timer.checkin` is the second quote from the source video, built literally.** Every N
minutes the goose ambles over and asks what you're working on, hotkey primed. It's cheap
to build, it's context-free so it can never be *wrong*, and it's the fallback that keeps
the product useful while the confidence-based rules are still being tuned. Default off,
one-tap on, interval user-chosen.

`task.recurring` is the most valuable long-term rule and the hardest — it needs a
privacy-safe local signature for "the same kind of task" without storing what the task
was. Defer past v1; note it as the Phase 4 differentiator.

## Confidence and suppression

An interruption fires only if **all** hold:

1. A rule matched and its dwell condition is satisfied.
2. `confidence` ≥ the user's sensitivity threshold (a three-position "how pushy?" setting).
3. No AI context in the grace window ([02](02-detection-architecture.md) — fail open).
4. The rule's cooldown has elapsed.
5. The daily interruption budget isn't spent.
6. No suppression context is active ([04](04-mascot-and-interruptions.md)).

## Nag-fatigue controls

The #1 way this product dies. Controls, in order of importance:

- **Daily budget: 4 interruptions by default.** Hard cap, user-adjustable down to 1 or off.
  Tier 1 stares are cheaper and counted at ¼ weight.
- **Per-rule cooldown** so one rule can't dominate the budget.
- **Adaptive backoff.** Three consecutive dismissals of a rule silences that rule for 24h.
  Three consecutive dismissals overall drops every interruption one tier for the day.
- **Escalating snooze.** Snooze offers 30min → 2h → today → "stop suggesting this."
- **Never interrupt twice in the same context without an intervening AI use.** If you
  ignored the goose about this email, it doesn't get to ask again about this email.
- **Quiet hours** and a weekly interruption ceiling regardless of daily budget.

## Metric discipline

**The north star is accepted interruptions, never interruptions fired.**

Write this into the codebase, the dashboard, and the team's OKRs, because the temptation
to optimize the wrong number is structural — interruptions fired is the number that goes
up when the product gets worse.

Instrument, per rule:

| Counter | Why |
|---|---|
| `fired` | denominator |
| `accepted` | user took the handoff |
| `already_did` | fail-open miss — high values mean detection is wrong |
| `dismissed` | soft negative |
| `snoozed` / `muted` | hard negative — a muted rule is a bug report |
| `tier_reached` | is the ladder escalating too fast? |

A rule whose acceptance rate sits below ~15% over a meaningful sample should be pulled
from the rulebook remotely. This is the main reason the rulebook is a remote artifact:
**it makes rule quality an operational discipline rather than a release-cycle one.**
