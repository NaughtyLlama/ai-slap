# 08 — Roadmap & risks

## Phase 0 — Signal spike (2 weeks)

**Build:** menu-bar app, Accessibility permission, AX window titles, event-driven
collection, local SQLite log. Nothing else.

**Explicitly no interruptions, no goose, no backend, no accounts.**

**Do:** run it on 5 people for two weeks. Hand-label the resulting logs. Answer one
question with data:

> How accurately can "this is a manual-effort moment AI could have handled" be identified
> from bundle ID + window title + dwell time alone?

**Why this is first.** It de-risks the entire product and it settles the browser-extension
argument with evidence instead of opinion. If titles can't carry it, everything downstream
is a nag machine — and you want to know that in week 2, not month 6 with an animator on
retainer.

**Decision gate:**

| Result | Action |
|---|---|
| Precision ≥ ~70% on top rules | Ship as specced, titles only |
| ~50–70% | Add the AppleScript URL fallback ([02](02-detection-architecture.md), tier 2) |
| < 50% | **Stop and reconsider.** Either the consumer path needs the extension after all, or the premise needs rethinking |

## Phase 1 — MVP (4–6 weeks + art lead time)

- Rules engine + baked-in rulebook
- **Mascot, tiers 0–2 only** — ambient, side-eye, honk
- Suppression (screen share, camera, Focus, panic hotkey) — with its own test plan
- Handoff: hotkey, goose-click, goose-drag
- Local weekly report, narrated by the goose
- Shareable GIF/screenshot capture
- Local dashboard, data viewer, pause

**Commission the character art on day one of this phase.** It has lead time engineering
doesn't, it's on the critical path, and it's what people judge in the first three seconds.

**Ship to ~50 design partners.** Tiers 3–4 wait until design partners show where the
annoyance line actually sits — that's not a thing to guess at.

**Exit criteria:** acceptance rate ≥ 25%, D14 still-unpaused ≥ 40%, no suppression
failures reported.

## Phase 2 — Product (6–8 weeks)

- Accounts, magic-link auth, device JWTs
- Ingest API + counters, Postgres-backed
- Remote signed rulebook + CDN
- Weekly report email
- Notarized installer, Sparkle updates, staged rollout
- Mascot tiers 3–4 behind opt-in
- Pro tier and billing

**Exit criteria:** 1,000 actives, acceptance rate holding, support load per user
understood.

## Phase 3 — Team tier

- Org enrollment, roles, admin policy
- Aggregate adoption dashboard with the k-anonymity floor
- SSO via WorkOS
- MDM `.pkg` + configuration profile
- Custom AI destination for internal gateways
- Security review pack ([07](07-privacy-and-enterprise.md))
- *Optionally:* MDM-deployed browser extension as an enterprise accuracy upgrade

**Before building this: validate the goose with 2–3 real buyers.** See the commercial risk
below.

## Phase 4 — Scale

- ClickHouse migration (trigger: >500k counter rows/day)
- Rulebook authoring tooling, per-rule staged rollout and acceptance dashboards
- `task.recurring` detection — the long-term differentiator
- **Windows client**
- SOC 2 Type II

## Risks, ranked

### 1. Nag fatigue — the most likely cause of death

Every accountability tool converges on being muted. The mascot is the mitigation, but **a
badly tuned mascot makes it worse** — a cartoon character nagging you is more irritating
than a notification, not less.

*Mitigations:* tier distribution is the number to instrument (tier 1 should dominate);
hard daily budget; adaptive backoff; pull rules remotely when acceptance drops; and never,
ever optimize interruptions fired.

### 2. Mascot appears during a demo or screen share

Reputationally fatal and unrecoverable for that account. Detecting third-party screen
capture on macOS is genuinely hard ([04](04-mascot-and-interruptions.md)).

*Mitigations:* conservative conferencing allowlist that over-hides; camera/mic state;
panic hotkey taught in onboarding; a dedicated suppression test plan run every release.

### 3. Battery and CPU from a resident animated character

*Mitigations:* 0% idle CPU as an acceptance criterion; automated performance test in CI;
`powermetrics` in the release checklist.

### 4. False negatives on AI use

Telling someone they skipped AI right after they used Claude in a tab is the fastest
uninstall available.

*Mitigations:* fail open; AI-context grace window; "I already did" on every interruption;
treat a high `already_did` rate as a detection bug, not user error.

### 5. Permission friction crushing the install funnel

*Mitigations:* exactly one prompt at onboarding; Screen Recording deferred to first
handoff; plain-language pre-prompts; in-app permissions diagnostic.

### 6. Apple tightening TCC

AX title access could be restricted in any annual release, as `kCGWindowName` was in
10.15.

*Mitigations:* beta-OS test matrix from Phase 2; the AppleScript and extension fallbacks
exist as redundancy; rulebook can disable broken rules remotely without an app update.

### 7. Spyware perception in security review

*Mitigations:* the entire architecture in [07](07-privacy-and-enterprise.md); consider
open-sourcing the detection layer.

### 8. Desktop Goose trade dress

*Mitigations:* original character, original art, work-for-hire assignment, IP counsel
before commissioning.

## ⚠️ Two decisions to make deliberately

**The goose cuts both ways commercially.** It is simultaneously your best consumer growth
asset — Desktop Goose spread entirely through people filming their screens — and the thing
a conservative CIO points at to say no. This spec resolves it as *full goose for
individuals, admin-capped at work*, betting that bottom-up adoption opens accounts that
top-down sales wouldn't reach. **Validate with two or three real buyers before Phase 3.**
If enterprise recoils, the fallback is a mascot-off default for team seats — which costs
you the distribution mechanic but keeps the deals.

**Mac-only caps the enterprise market hard.** Most enterprise seats are Windows. The
Windows equivalent (UIAutomation for window titles, WPF/WinUI for the mascot overlay) is a
comparable but separate build — realistically a second client team. This shapes how you
sell: Mac-only lands design-forward companies and startups, and stalls in large
enterprises where procurement wants full-fleet coverage. **Decide before Phase 3**, since
it determines whether the team tier is sold as "for your Mac users" or "for everyone."

## Metrics

| Metric | Definition | Target |
|---|---|---|
| **North star** | AI-assisted moments/user/week | grows month over month |
| Acceptance rate | accepted ÷ fired | ≥ 25%, never below 15% |
| Activation | permissions granted + first handoff within 24h | ≥ 60% |
| D30 unpaused | still allowing interruptions at 30 days | ≥ 35% |
| `already_did` rate | fail-open misses | < 10% |
| Seats per account | expansion | grows |

**Retention means still-unpaused, not still-installed.** An app sitting paused in the menu
bar is churned; counting it as retained is how you lie to yourself for two quarters.
