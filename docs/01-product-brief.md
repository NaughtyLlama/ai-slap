# 01 — Product brief

## The problem

Most knowledge workers who *have* access to AI tools still don't reach for them. Not out
of skepticism — out of habit. The email gets answered by hand because answering email by
hand is what fingers do. The blank doc gets stared at. The spreadsheet formula gets
googled. The tool is one tab away and stays there.

The gap isn't knowledge or access. It's the half-second at the start of a task where you
choose a path without noticing you chose. Nothing intervenes in that half-second, so
nothing changes. Companies buying AI seats discover this the expensive way: high license
counts, low weekly actives.

The framing this product borrows from is a human one. AI trainers get hired to sit next
to people and interrupt them — to notice the moment and say *not like that, like this.*
That works, and it doesn't scale. This is an attempt to make the cheap version of it.

## The core loop

```
observe → classify → interrupt → hand off → reinforce
```

1. **Observe** which app is frontmost and what the window is called.
2. **Classify** whether this is a manual-effort moment AI could have handled.
3. **Interrupt** — a goose notices, and escalates from a stare to a honk.
4. **Hand off** — one click captures the window and drops it into Claude, prompt written.
5. **Reinforce** — the goose's mood tracks your week; the weekly report is its report card.

Step 4 is what makes steps 1–3 tolerable. An interruption that only judges you is a nag.
An interruption that does the work when you click it is a shortcut.

## Users

**Primary — the AI-curious knowledge worker.** Has Claude or ChatGPT open somewhere. Uses
it a few times a week and knows it should be a few times an hour. Marketing, sales, ops,
support, product, founders. Not engineers first — engineers already have AI in the editor.

**Secondary — the person who bought everyone seats.** Head of ops, chief of staff, an
enablement lead, sometimes a CTO. Has license spend and no adoption. Needs a number to
show, and needs it without a works-council fight.

**Explicitly not for:** anyone whose employer wants to monitor them. If the buyer's
motivation is surveillance rather than enablement, this is the wrong product and the
aggregate-only reporting in [07](07-privacy-and-enterprise.md) will make that clear
early. That constraint is a feature — it's what keeps employees willing to install it.

## Competitive gap

| Product | What it does | What it doesn't |
|---|---|---|
| [ActivityWatch](https://activitywatch.net/) | Open-source, local-first, cross-platform time tracking | No AI layer, no intervention, raw data you process yourself |
| Rize | Cloud time-tracking with AI categorization, polished Mac app | Retrospective dashboards; never interrupts, never acts |
| Dayflow | Screen capture every 10s, AI-written timeline of your day | Retrospective; heavy capture posture; no nudging |
| RescueTime | Category-based productivity scoring, focus sessions | Blocks distractions; has no opinion about *how* you work |
| Desktop Goose | A goose on your desktop, for its own sake | Not a productivity tool and doesn't pretend to be |

**Everyone in the time-tracking column builds rear-view mirrors.** They tell you on Friday
what you did on Tuesday. Nobody intervenes at the moment of choice, and nobody closes the
loop by doing the task for you.

That's the gap: **intervention plus handoff, at the moment it matters.** The mascot is how
the intervention stays welcome, and it's a category nobody in the productivity column
would think to enter.

## Positioning

**We are:** a coach with a sense of humor that lives on your desktop.

**We are not:** employee monitoring. This is the perception fight in every enterprise
deal, and it's why several design choices are non-negotiable — on-device classification,
aggregate-only admin views, a pause button that genuinely pauses.

The mascot does real positioning work here. A tool with a cartoon goose on it does not
read as surveillance software, and no amount of privacy-policy copy would buy that
impression as cheaply.

## Growth model

**The goose is the marketing.** Desktop Goose spread almost entirely through people
filming their own screens and posting it. That's the distribution bet: the product is
inherently demonstrable, and a good honk is shareable in a way a dashboard never is.

Consequences for the build:
- **Shareable moments are a product feature.** One-click GIF/screenshot capture of a good
  interruption, watermarked, ready to paste into Slack. Build it in Phase 1, not as polish.
- **The individual tier must be genuinely free or near-free.** It's the top of the funnel
  into the paid team tier, and paywalling the goose kills the distribution mechanic.
- **Land-and-expand.** Someone installs it themselves, their team asks what that is, the
  company buys seats. This is why bottom-up UX matters more than enterprise features on
  day one.

## Pricing

| Tier | Price | Contents |
|---|---|---|
| Free | $0 | Full goose, all detection, handoff, local weekly report |
| Pro | ~$10/mo | Custom rules, history beyond 30 days, multiple AI destinations, mascot skins |
| Team | ~$8–12/seat/mo | Aggregate adoption dashboard, SSO, MDM deployment, admin policy, custom AI gateway |

The free tier is deliberately generous. The paid unlock is not the nagging — it's the
reporting and the administration, which is what the actual buyer wants anyway.

⚠️ **Unvalidated.** These are placeholders shaped by comparable prosumer Mac tools, not by
customer conversations. Price discovery belongs in the Phase 1 design-partner cycle.

## What success looks like

Ordered by how much they'd tell you:

1. **AI-assisted moments per user per week** — the north star. Accepted interruptions plus
   handoff invocations.
2. **Acceptance rate** — accepted ÷ fired. If this drops below ~20% the goose is a nag and
   the rulebook is wrong. Never optimize interruptions fired.
3. **D30 still-unpaused** — not installs, not opens. Retention means the goose is still
   allowed to interrupt after a month.
4. **Seats per account** — measures whether land-and-expand actually works.
