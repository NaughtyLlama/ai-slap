# AI-slap

A macOS menu-bar app with a desktop mascot that watches which app you're in, notices when
you're doing something by hand that AI could do, interrupts you about it, and hands the
task to Claude in one gesture.

**This file mirrors [`CLAUDE.md`](CLAUDE.md) so non-Claude agents route the same way. Keep
the two in sync — if you change one, change the other.**

## Read this first

| You want | Go to |
|---|---|
| **What state is this in? What do I do next?** | [`HANDOFF.md`](HANDOFF.md) — always start here |
| Why is the code like this? What already went wrong? | [`NOTES.md`](NOTES.md) |
| What is the product, and what was specced? | [`README.md`](README.md), then `docs/01`–`08` in order |
| How detection works | `docs/02` — most load-bearing technical doc |
| The mascot, escalation, suppression | `docs/04` |

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
  NudgePanel.swift                     the interruption window (the mascot's home)
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
```

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
