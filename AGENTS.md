# AI-slap

A macOS menu-bar app with a desktop mascot that watches which app you're in, notices when
you're doing something by hand that AI could do, interrupts you about it, and hands the
task to Claude in one gesture.

**This file mirrors [`CLAUDE.md`](CLAUDE.md) so non-Claude agents route the same way. Keep
the two in sync — if you change one, change the other.**

## Current state — read [`HANDOFF.md`](HANDOFF.md) first

**`HANDOFF.md` is where the session state lives**: what works right now, Chen's settings
and why they are non-default, what to check first, and what to pick up next. It is
rewritten at the end of every working session.

This file is the opposite — durable orientation that should rarely change. **Do not put
dated state, current settings, or next steps here.** They go stale silently and then
mislead, which is worse than not being written down at all.

## Start here

Read [`README.md`](README.md) first, then the docs in order. `docs/02` (detection) and
`docs/04` (mascot) carry the most load-bearing technical detail.

## Where the code is

Phase 0 (the `docs/08` signal spike), the rules engine (`docs/03`) and the handoff
(`docs/05`) are built. No mascot, no backend, no accounts.

```
Package.swift                          SwiftPM manifest (no Xcode project by design)
Sources/AISlap/
  main.swift                           NSApplication bootstrap, .accessory policy
  AppDelegate.swift                    session open/close, permissions, menu actions
  WindowContext.swift                  the observed-context and session types
  WindowContextObserver.swift          tier 0 + tier 1 detection
  SessionStore.swift                   local SQLite log + CSV export
  SessionStore+Analytics.swift         dwell history and interruption outcomes
  Rulebook.swift                       rule schema, loading, compiled matching
  Personalizer.swift                   per-user adaptation (see below)
  InterruptionEngine.swift             gating + notification delivery
  Handoff.swift                        capture → prompt → clipboard → paste
  WindowCapture.swift                  ScreenCaptureKit, one window only
  AIDestination.swift                  where a handoff goes
  Pasteboard.swift                     staging, restore, synthesised keystrokes
  GlobalHotkey.swift                   ⌥Space via Carbon
  MenuBarController.swift              the entire UI
Resources/rulebook.json                baked-in default rulebook
Resources/Info.plist                   LSUIElement, bundle ID, version
scripts/build-app.sh                   source → AISlap.app, Command Line Tools only
scripts/make-signing-identity.sh       run once; stops rebuilds revoking Accessibility
```

Build and run:

```bash
./scripts/build-app.sh --run
```

Log lives at `~/Library/Application Support/AISlap/phase0.sqlite`. Never in the repo.

## The rulebook / Personaliser split

**The rulebook says what a context *is*. The Personaliser says what is unusual *for
you*.** Keeping these apart is the load-bearing idea in the client.

The rulebook is generic and identical for everybody, which is what lets it become the
shared, signed, remotely-updatable artifact `docs/03` requires. Patterns are written
from published window-title formats — never reverse-engineered from one person's log.

**This is where the product's biggest open question lives.** A heavy AI user generates
very little for the rulebook to catch — most of their observed time already *is* AI —
and their manual-work moments are short, interleaved gaps rather than long sits. The
premise catches people defaulting to manual work; someone who already defaults to AI is
close to a null case. Worth resolving before drawing a goose.

The Personaliser never leaves the device and adapts three things:

1. **Dwell thresholds** become a high percentile (p85) of *your own* dwell times in
   that category. A fixed 90-second email rule is wrong for nearly everyone: someone
   who clears mail in 20-second bursts never trips it and concludes the app is broken;
   someone who lives in 6-minute threads gets pestered. Bounded above at 2.5× the
   rulebook value and below only by a 20s floor — deliberately no lower *multiple*,
   see deviation 7.
2. **Per-rule trust** — a Beta posterior over accept/dismiss, shrunk toward the
   rulebook default until ~6 resolved outcomes. Below 15% useful over 12+ outcomes the
   rule mutes itself locally, mirroring the remote pull in `docs/03`.
3. **Time-of-day receptivity** — if you never take a nudge before 10am, it stops
   asking before 10am.

Cold start behaves exactly as specced and drifts from there. **"What it's learned about
you…" in the menu prints all of it in plain language** — a system that quietly retunes
itself has to show its work, or the first surprising silence reads as a bug.

## Decisions already made — don't relitigate without a reason

- **Detection is bundle ID + Accessibility window title.** No screen capture as a
  baseline signal.
- **Use the Accessibility API, not `CGWindowListCopyWindowInfo`**, to read window titles.
  The latter requires Screen Recording permission since macOS 10.15.
- **No browser extension in the consumer path.** One app, one permission prompt. The
  extension exists only as an optional MDM-deployed enterprise upgrade in Phase 3.
- **All classification is on-device.** The server receives anonymous counters only —
  never a title, URL, or pixel. This is what makes 100k MAU cheap *and* enterprise-viable.
- **Interruptions are a desktop mascot, and the mascot is also the handoff button.** A
  mascot that only nags gets muted.
- **Native Swift + SpriteKit, distributed outside the Mac App Store.** The MAS sandbox
  effectively forbids the Accessibility API this depends on. Electron cannot do a
  transparent, click-through, non-activating always-on-top overlay reasonably.
- **SwiftPM, not an `.xcodeproj`.** The Command Line Tools build, sign, notarize and
  staple without Xcode. Install Xcode when the SpriteKit mascot needs a live preview —
  a SwiftPM package opens in it directly, so this is not a one-way door.
- **Never auto-submit** a handoff. The user reads what's about to be sent.
- **The north star is accepted interruptions, never interruptions fired.**

## Deviations from the spec — deliberate, and load-bearing

Where the shipped code knowingly departs from the docs, and why.

1. **Raw window titles are written to disk.** `docs/02` says a title is reduced to a
   category token within the tick and the raw string discarded. The Phase 0 log cannot
   do that: hand-labelling real titles *is* its deliverable. Confined to
   `SessionStore.swift` and marked ⚠️ there. The rules engine already works on category
   tokens, so **when labelling is finished, cut the raw-title column rather than
   extending it.** The engine will not need changing.
2. **An `AXObserver` supplements the workspace notification.**
   `NSWorkspace.didActivateApplicationNotification` only fires on app switches, so it
   never sees a browser tab change or a Gmail message opening — the highest-value signal
   in the product. `kAXTitleChangedNotification` on the focused window covers it. A
   10-second reconcile timer backstops apps with unreliable AX notifications. Still
   event-driven; the 1 Hz poll `docs/02` warns against is not what's happening.
3. **AI-context title patterns apply to browser windows only.** Matching model names
   against any window title is not survivable: an Obsidian vault named "Claude Working
   Folder" classified every note as AI use, opening a rolling 10-minute amnesty that
   silenced every rule invisibly. `docs/02` names this ambiguity; the fix is that
   `aiContexts.browserTitlePatterns` is consulted only when the frontmost app is a
   browser, where the title really is the page `<title>`, and the patterns are anchored
   rather than bare word matches. A false positive here is far more expensive than a
   missed nudge, because it silences the product without telling anyone.
4. **Returning to a context within 5s extends the previous session.** A sub-2s flicker
   between two halves of one sit would otherwise split it, and dwell is what every rule
   triggers on — a 90-second email logging as 40 + 24 loses the trigger silently.
5. **Only AI-native editors count as AI contexts.** `docs/02` accepts treating AI-native
   editors as AI wholesale. That reasoning does not extend to general editors: listing
   VS Code would silence the product for anyone who writes code all day.
6. **The AI amnesty is a user setting, and can be switched off entirely.** `docs/02`
   fixes it at 10 minutes and calls it fail-open. That holds for occasional AI users and
   **inverts for heavy ones**: their pattern is to start something with AI and move to
   another window while it runs, so the amnesty blinds the product to its single best
   trigger and goes silent for its most engaged users — the opposite of what fail-open
   was for. The escape hatch `docs/02` actually depends on is the "I already did"
   button, which is on every nudge regardless of this setting. With the amnesty off, an
   AI context no longer clears the already-nudged set either, or passing through Claude
   would re-arm every context the user had just declined.
7. **Learned thresholds have no lower bound beyond a 20s floor.** They were clamped to
   0.4×–2.5× of the rulebook value, which defeated the point: a user whose real sits
   average 17 seconds had a learned 19s threshold dragged back up to 48s, so nothing
   ever fired. Fast workers are precisely who personalisation exists for. The ceiling
   stays; the daily budget and per-rule cooldowns are what actually cap firing rate.

## Open questions — marked ⚠️ throughout the docs

1. Are window titles accurate enough alone? **Partly answered, informally.** One
   person's log showed Gmail, Slack, Obsidian and search titles all classify cleanly,
   which was enough for the owner to proceed. Precision was never measured against
   hand-labels, so the honest status is "promising, unquantified" — not "passed".
2. Mac-only caps the enterprise market. Windows client, and when?
3. Does the goose open doors or close them with real buyers?
4. Pricing in `docs/01` is a placeholder, not validated.
5. AI deep-link URL parameters change — verify against vendor docs at build time.

## The gate that was skipped, and what it costs

The formal `docs/08` decision gate — two weeks, five people, hand-labelled precision —
was **deliberately skipped by the owner as too heavy for this stage.** What replaced it:
one person's real log confirmed that Gmail titles separate "one open message" from
"inbox" cleanly, which was the assumption the gate existed to protect. Rules were written
from published title formats and then checked against that log.

**Treat every precision number as unmeasured, because it is.** Nothing here has been
validated against hand-labels, and no second user has ever run it. Say so plainly rather
than implying the rules are known-good.

Distribution is blocked on an Apple Developer ID; the local self-signed identity fixes
the development loop only.

## Traps that already cost a day

Permanent, not session state. Each of these produced a bug that looked like
something else entirely.

- Swift's synthesised `Decodable` throws on a missing key rather than using a property
  default. Any optional rulebook field needs explicit `decodeIfPresent`.
- Matching AI names against non-browser window titles silences the whole product: an
  Obsidian vault called "Claude Working Folder" read as continuous AI use.
- `NSPasteboard` written once with text and image makes two items, and composers read
  only the first. Paste them separately.
- A non-activating panel never becomes key, so AppKit will not draw a default button in
  the accent colour, and `behindWindow` blending samples the desktop — both produced
  invisible UI in light mode only.
- OpenSSL 3 writes a PKCS#12 macOS refuses to import; `-legacy` and a non-empty
  passphrase are both required.


## Conventions

- Specs live in `docs/`, numbered. Keep them updated as decisions change — a stale spec
  is worse than none.
- ⚠️ marks an unvalidated assumption or a decision needing external verification. Preserve
  the marker until it's actually resolved.
- No network code in the client target. Not stubbed — absent, until Phase 2.
- **State goes in `HANDOFF.md`, not here.** This file, `AGENTS.md` and `docs/` are
  durable; `HANDOFF.md` is the only file that describes the present moment. Rewrite it at
  the end of a working session rather than appending to it — a log of past sessions is
  not a handoff.
- `AGENTS.md` is a generated mirror of this file. Edit `CLAUDE.md`, then copy it across
  with the header line swapped.
