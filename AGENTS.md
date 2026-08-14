# AI-slap

A macOS menu-bar app with a desktop mascot that watches which app you're in, notices when
you're doing something by hand that AI could do, interrupts you about it, and hands the
task to Claude in one gesture.

**This file mirrors [`CLAUDE.md`](CLAUDE.md) so non-Claude agents route the same way. Keep
the two in sync — if you change one, change the other.**

## Start here

Read [`README.md`](README.md) first, then the docs in order. `docs/02` (detection) and
`docs/04` (mascot) carry the most load-bearing technical detail.

## Where the code is

Phase 0 — the signal spike from `docs/08` — is built. Nothing beyond it exists.

```
Package.swift                          SwiftPM manifest (no Xcode project by design)
Sources/AISlap/
  main.swift                           NSApplication bootstrap, .accessory policy
  AppDelegate.swift                    session open/close, permission, pause
  WindowContext.swift                  the observed-context and session types
  WindowContextObserver.swift          tier 0 + tier 1 detection
  SessionStore.swift                   local SQLite log + CSV export
  MenuBarController.swift              the entire UI
Resources/Info.plist                   LSUIElement, bundle ID, version
scripts/build-app.sh                   source → AISlap.app, Command Line Tools only
```

Build and run:

```bash
./scripts/build-app.sh --run
```

Log lives at `~/Library/Application Support/AISlap/phase0.sqlite`. Never in the repo.

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
  effectively forbids the Accessibility API this depends on.
- **SwiftPM, not an `.xcodeproj`.** The Command Line Tools build, sign, notarize and
  staple without Xcode. Install Xcode when the SpriteKit mascot needs a live preview —
  a SwiftPM package opens in it directly, so this is not a one-way door.
- **Never auto-submit** a handoff. The user reads what's about to be sent.
- **The north star is accepted interruptions, never interruptions fired.**

## Phase 0 deviations from the spec — deliberate, and load-bearing

Two places where the shipped code knowingly departs from the docs. Both are Phase 0 only.

1. **Raw window titles are written to disk.** `docs/02` says a title is reduced to a
   category token within the tick and the raw string discarded. Phase 0 cannot do that:
   hand-labelling real titles *is* the deliverable. The exception is confined to
   `SessionStore.swift` and marked ⚠️ there. **Delete that file when the rules engine
   lands — do not extend it.**
2. **An `AXObserver` supplements the workspace notification.**
   `NSWorkspace.didActivateApplicationNotification` only fires on app switches, so it
   never sees a browser tab change or a Gmail message opening — which is the highest-value
   signal in the product. `kAXTitleChangedNotification` on the focused window covers it.
   A 10-second reconcile timer backstops apps with unreliable AX notifications. This is
   still event-driven; the 1 Hz poll `docs/02` warns against is not what's happening.

## Open questions — marked ⚠️ throughout the docs

1. Are window titles accurate enough alone? **Phase 0 answers this with data.** Don't
   build past it without running the spike — see `docs/08`.
2. Mac-only caps the enterprise market. Windows client, and when?
3. Does the goose open doors or close them with real buyers?
4. Pricing in `docs/01` is a placeholder, not validated.
5. AI deep-link URL parameters change — verify against vendor docs at build time.

## What happens next

Phase 0 is built but **unanswered**. Run it, hand-label the CSV, and compare against the
decision gate in `docs/08` before writing rules, a mascot, or a backend. The gate exists
so question 1 gets settled with data rather than enthusiasm.

Distribution is blocked on an Apple Developer ID. Until then builds are ad-hoc signed and
macOS may drop the Accessibility grant on rebuild, since TCC keys the permission to the
code signature.

## Conventions

- Specs live in `docs/`, numbered. Keep them updated as decisions change — a stale spec
  is worse than none.
- ⚠️ marks an unvalidated assumption or a decision needing external verification. Preserve
  the marker until it's actually resolved.
- No network code in the client target. Not stubbed — absent, until Phase 2.
