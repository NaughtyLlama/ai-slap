# AI-slap

A macOS menu-bar app with a desktop mascot that watches which app you're in, notices when
you're doing something by hand that AI could do, interrupts you about it, and hands the
task to Claude in one gesture.

**This file mirrors [`CLAUDE.md`](CLAUDE.md) so non-Claude agents route the same way. Keep
the two in sync — if you change one, change the other.**

## There is only one copy of this repository

`<the repo>`. If you are reading this
anywhere else — `~/Documents/GitHub/ai-slap` is where GitHub Desktop puts clones — stop
and work in the path above instead.

A whole milestone was once implemented against that other clone while it sat five commits
behind, and turning a merge into a hand-port cost more than the fixes did. Before editing
any repository, `git remote get-url origin` and `git log -1`, and look for a second clone
of the same remote. See `NOTES.md`.

## Read this first

| You want | Go to |
|---|---|
| **What state is this in? What do I do next?** | [`HANDOFF.md`](HANDOFF.md) — always start here |
| Why is the code like this? What already went wrong? | [`NOTES.md`](NOTES.md) |
| What is the product, and what was specced? | [`README.md`](README.md), then `docs/01`–`08` in order |
| How detection works | `docs/02` — most load-bearing technical doc |
| The mascot, escalation, suppression | `docs/04` |
| What Doug looks like, and why | `Doug.dc.html` — open it in a browser |

**This file is a router, not a log.** It should rarely change. Current state goes in
`HANDOFF.md`, reasoning and post-mortems go in `NOTES.md`. Anything dated that lands here
goes stale silently and then misleads.

## Where the code is

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
  Personalizer.swift                   per-user adaptation
  InterruptionEngine.swift             gating + delivery
  NudgePanel.swift                     the interruption window — Doug's speech bubble
  DougSprite.swift                     the pixel grids, copied verbatim from Doug.dc.html
  DougWindow.swift                     Doug on the desktop, the tier ladder, taste settings
  Suppression.swift                    when nothing may appear
  Handoff.swift                        capture → prompt → clipboard → paste
  WindowCapture.swift                  ScreenCaptureKit, one window only
  AIDestination.swift                  where a handoff goes
  Pasteboard.swift                     staging, restore, synthesised keystrokes
  GlobalHotkey.swift                   ⌥Space and ⌥⌘G via Carbon
  MenuBarController.swift              the menu
Resources/rulebook.json                rules, AI contexts, destinations, suppression
Resources/Info.plist                   LSUIElement, bundle ID, version
scripts/build-app.sh                   source → AISlap.app, Command Line Tools only
scripts/make-signing-identity.sh       run once; stops rebuilds revoking Accessibility
scripts/design-preview.sh              renders Doug + the bubble offscreen, to PNGs
Doug.dc.html                           the design canvas — the source for the sprite
```

- `parking-lot.md` — important but not right now. Deferred asks, dated, with who raised them. Check it before asking Chen what's next; add to it instead of losing an idea.

```bash
./scripts/build-app.sh --run
```

Log lives at `~/Library/Application Support/AISlap/phase0.sqlite`. Never in the repo.

## Decisions already made — don't relitigate without a reason

- **Detection is bundle ID + Accessibility window title.** No screen capture as a
  baseline signal.
- **Use the Accessibility API, not `CGWindowListCopyWindowInfo`**, to read window titles.
  The latter requires Screen Recording permission since macOS 10.15.
- **No browser extension in the consumer path.** One app, one permission prompt.
- **All classification is on-device.** The server receives anonymous counters only —
  never a title, URL, or pixel.
- **Interruptions are a mascot, and the mascot is also the handoff button.** A mascot
  that only nags gets muted.
- **The mascot is Doug — a hermit crab in a dead CRT, and the screen is his face.**
  Original character by design, which also settles the Desktop Goose trade-dress problem
  in `docs/04`. `Doug.dc.html` is the source of truth for how he looks; `DougSprite.swift`
  copies its pixel grids verbatim rather than exporting images, so the two can't drift.
- **Native Swift, distributed outside the Mac App Store.** The sandbox forbids the
  Accessibility API this depends on.
- **SwiftPM, not an `.xcodeproj`.** Command Line Tools build, sign, notarise and staple
  without Xcode. Not a one-way door — a package opens in Xcode directly.
- **The rulebook is generic; personalisation is separate and on-device.** See `NOTES.md`.
- **Never auto-submit** a handoff. The user reads what's about to be sent.
- **The north star is accepted interruptions, never interruptions fired.**

## Conventions

- Specs live in `docs/`, numbered. A stale spec is worse than none.
- ⚠️ marks an unvalidated assumption or a decision needing external verification.
  Preserve the marker until it's actually resolved.
- No network code in the client target. Not stubbed — absent, until Phase 2.
- **Three files, three jobs.** `CLAUDE.md` routes and rarely changes. `HANDOFF.md` is
  rewritten each session and is the only description of the present. `NOTES.md` is
  appended to and explains why. Putting the wrong thing in the wrong one is how these
  rot.
- `AGENTS.md` is a generated mirror of this file. Edit `CLAUDE.md`, then copy it across
  with the header line swapped.
