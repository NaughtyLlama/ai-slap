# 07 — Privacy & enterprise

This product reads your window titles and lives on your screen. It only works if people
believe it isn't spying on them — and the only durable way to be believed is to build it
so that spying is architecturally impossible rather than merely against policy.

## The data contract

State this publicly, in plain language, and hold to it:

1. **Classification happens on your device.** Window titles are matched against patterns
   and immediately reduced to a category token. The raw title is never written to disk and
   never leaves the machine.
2. **We never see your screen.** Screenshots occur only when *you* trigger a handoff, go
   straight to your clipboard and your AI tool, and are never transmitted to us or stored.
3. **What syncs is counters.** "Rule 14 fired, you accepted." No titles, no URLs, no app
   names beyond a coarse category, no content.
4. **Your local history is yours.** Kept until you delete it, a viewer that shows
   everything stored, one-click wipe, optional retention limits.

   *Changed 2026-09-10, and the change was the user's:* the default was a rolling
   30-day window. Chen asked for long-term history instead, because the value of a
   usage record is the shape it takes over months — and a product that quietly
   destroys your own data on a timer is making that decision for you. Shortening
   retention is now an opt-in with a confirmation, since picking 30 days deletes
   everything older the moment you pick it.
5. **Pause means paused.** The menu-bar pause stops collection, not just interruptions.

Point 5 deserves emphasis: a pause button that keeps collecting is the kind of detail
that, when discovered, ends a company. Make it a real kill switch on the collector.

## Local storage

SQLite at `~/Library/Application Support/<app>/`, `NSFileProtection`-equivalent
permissions, containing:

| Stored | Not stored |
|---|---|
| Category tokens (`gmail.message.open`) | Raw window titles |
| Dwell durations | URLs or paths |
| Rule IDs, outcomes, timestamps | Screenshots |
| App name and bundle id | Keystrokes or clipboard |
| Doug's mood state, streaks | Title-derived daily totals |

That last cell is the subtle one. Some rules need to know how long you have spent on a
surface today, and a surface is derived from the window title — so the total is derived
from something that may not be written down. It lives in memory, it is exact while the
app runs, and it is gone when the app quits. A number that could reconstruct what the
title said does not get a row in a database.

Kept until deleted, with 30/90/365-day limits available. Pruning runs at most hourly
rather than only on launch, because an app that stays open for a fortnight otherwise
never enforces the limit its owner chose.

The **data viewer** is a real product surface, not a compliance checkbox — a plain
summary of everything held, exportable as CSV, with a delete button. Users who inspect
it become the people who vouch for you.

**Delete means delete.** The erase path clears sessions, outcomes, learned adjustments,
muted rules, the merge cache, in-memory totals and any export the app wrote, then
`VACUUM`s the file so freed pages carrying old text are actually overwritten. Exports
you copied somewhere else are yours and are not touched — the alert says so, because a
delete button that silently misses something is worse than one that admits its edges.

**Migration is one-way and it is the point.** A database written by an earlier build
still carries raw titles in columns that no longer exist. Opening it rebuilds the table
without them and preserves every other historical row, so upgrading destroys the titles
and keeps the history.

## Admin reporting: aggregate only

**The hard guarantee: admins never see individual behavior.**

| Admins see | Admins never see |
|---|---|
| Team adoption: "34% of eligible moments" | Per-person adoption |
| Trend over time | Per-person anything |
| Adoption by department (≥5 people) | App or site breakdowns per person |
| Seat utilization: active vs dormant | Window titles, URLs, screenshots |
| Aggregate top opportunity categories | Who ignored the goose |

Enforced technically, not by policy:

- **k-anonymity floor of 5.** Any cohort with fewer than 5 contributing users returns
  "insufficient data." Enforced in the query layer so no dashboard, export, or API can
  bypass it.
- **No per-user endpoint exists** in the admin API. Not gated — absent.
- **Seat utilization is binary** (active / dormant), which is what license management
  actually needs, and deliberately not a productivity score.

⚠️ **Some buyers will ask for per-person reporting.** The answer is no, and it should be a
loud no. Three reasons, in the order that persuades them: employees stop installing it and
your adoption number dies; it turns a works-council conversation from routine into a fight;
and it moves you into the employee-monitoring category where you compete with entrenched
vendors on their terms instead of yours. A buyer who insists is a buyer whose employees
will uninstall this in month two.

## Compliance

⚠️ **Not legal advice.** These are the factors to route to actual counsel before an EU or
enterprise launch.

- **GDPR Art. 6** — establish a lawful basis. Consent is weak in an employment context
  (power imbalance); legitimate interest is the usual route and requires a documented
  balancing test.
- **GDPR Art. 88 + national law** — member states regulate employee monitoring
  specifically, and the rules differ meaningfully by country.
- **DPIA** — likely required for systematic workplace monitoring. Do it early; it also
  produces the document security reviewers ask for.
- **Works councils** — Germany, France, the Netherlands and others require consultation
  before deployment. This can add months to an enterprise rollout, and aggregate-only
  reporting is the single biggest factor in how that conversation goes.
- **CCPA/CPRA** — California employee notice at or before collection.
- **Data residency** — EU customers will ask. Counters-only makes an EU ingest region
  cheap to offer.

**Clear by design:** no audio (no wiretap exposure), no biometrics (no BIPA exposure), no
content capture. ⚠️ Adding face detection, emotion detection, or audio would drag you into
BIPA and wiretap territory — a standing reason never to add them.

## Security review pack

Enterprise deals stall on security review. Prepare these once, in Phase 3:

- **Permissions justification table** — every TCC permission, why it's needed, what
  breaks without it.
- **Data flow diagram** — what leaves the device, to where, in what form.
- **Subprocessor list** — cloud, auth, error reporting, analytics.
- **SBOM and dependency policy.**
- **Pen test** — annual third-party, summary letter shareable under NDA.
- **SOC 2 Type II** — expect it to be required above ~500 seats. Start the observation
  window a year before you think you need it.
- **Incident response plan** with a stated notification SLA.

## Trust as a product surface

Trust is built by things users can *see*, not by a policy page:

- Onboarding explains each permission in one sentence, in the user's terms, before the
  system dialog appears.
- The data viewer is one click from the menu bar.
- Pause is the first item in the menu.
- The goose visibly sleeps when paused — the state is legible at a glance, which is worth
  more than any settings screen.
- Open-source the detection layer. ⚠️ Worth serious consideration: it's the component
  people are suspicious of, it's not where the defensible value sits (that's the rulebook,
  the mascot, and the team product), and publishing it converts the biggest objection into
  the strongest proof.
