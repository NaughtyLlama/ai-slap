# AI-slap

Press ⌥Space on any window. It photographs that window, opens a new chat in your AI, and
pastes it in with whatever you want to ask. Doug the hermit crab lives on the desktop and
is the same button. It keeps no screenshot history; clipboard and destination privacy still apply.

**This file mirrors [`CLAUDE.md`](CLAUDE.md) so non-Claude agents route the same way. Keep
the two in sync — if you change one, change the other.**

## Check you are in the only clone

A whole milestone was once implemented against a second clone of this repo while it sat
five commits behind, and turning a merge into a hand-port cost more than the fixes did.
GitHub Desktop puts clones in `~/Documents/GitHub/` without saying so.

Before editing any repository: `git remote get-url origin` and `git log -1`, then look
for another clone of the same remote. `HANDOFF.md` names the canonical path on this
machine. See `NOTES.md` for how that went.

## Read this first

| You want | Go to |
|---|---|
| **What state is this in? What do I do next?** | `HANDOFF.md` — always start here. Local only, not in the repo |
| Why is the code like this? What already went wrong? | [`NOTES.md`](NOTES.md) |
| What the app does, step by step | [`docs/handoff.md`](docs/handoff.md) |
| What someone else is given when they receive it | [`docs/READ-ME-FIRST.md`](docs/READ-ME-FIRST.md) |
| What Doug looks like, and why | `Doug.dc.html` — open it in a browser |

**This file is a router, not a log.** It should rarely change. Current state goes in
`HANDOFF.md`, reasoning and post-mortems go in `NOTES.md`. Anything dated that lands here
goes stale silently and then misleads.

## Where the code is

```
Package.swift                          SwiftPM manifest (no Xcode project by design)
Sources/AISlap/
  main.swift                           NSApplication bootstrap, .accessory policy
  AppDelegate.swift                    wiring: hotkeys, menu, Doug, handoff results
  Onboarding.swift                     first run — what it does, which AI, two permissions
  WindowContext.swift                  the observed-context type
  WindowContextObserver.swift          which app and window is frontmost
  Rulebook.swift                       rule schema, loading, compiled matching
  NudgeEngine.swift                    the gates — all state in memory, nothing stored
  NudgePanel.swift                     the interruption — Doug's speech bubble
  Suppression.swift                    when nothing may appear
  Handoff.swift                        capture → review → open → guarded paste
  HandoffRecovery.swift                the review dialog, and the rescue panel
  WindowCapture.swift                  ScreenCaptureKit, one window, three ways to find it
  AIDestination.swift                  opening an AI app or its website
  Destinations.swift                   loads destinations.json, falls back to built-ins
  Pasteboard.swift                     ownership-checked staging, restore, keystrokes
  GlobalHotkey.swift                   ⌥Space and ⌥⌘G via Carbon
  MenuBarController.swift              the menu
  DougSprite.swift                     the pixel grids, copied verbatim from Doug.dc.html
  DougWindow.swift                     Doug on the desktop: wandering, dragging, moods
  LaunchAtLogin.swift                  the login item
Resources/rulebook.json                rules, AI contexts, destinations, suppression
Resources/AISlap.icns                  generated from the sprite by scripts/make-icon.sh
Resources/Info.plist                   LSUIElement, bundle ID, version, icon
scripts/build-app.sh                   source → AISlap.app, Command Line Tools only
scripts/package.sh                     → dist/AISlap.zip plus the note for recipients
scripts/make-signing-identity.sh       run once; stops rebuilds revoking Accessibility
scripts/make-icon.sh                   regenerate the icon when Doug changes
scripts/design-preview.sh              renders Doug offscreen, to a PNG
Doug.dc.html                           the design canvas — the source for the sprite
```

```bash
./scripts/build-app.sh --run
```

**No screenshot history or database.** Preferences are saved and diagnostic messages
are emitted. Clipboard and destination software can retain handoff content. Adding
content persistence is a product decision, not an implementation detail.

## Decisions already made — don't relitigate without a reason

- **It watches, but it does not remember.** The observer, the nine fixed rules and
  Doug's nudges are back. The SQLite log and the personaliser that learned from it are
  not, and should not come back without a reason — that log was 1,900 of the old 2,700
  lines and every piece of privacy machinery in this project existed to contain it.
  Every rule needs only what is true right now, so all of it lives in `NudgeEngine` and
  dies with the process. See `NOTES.md`.
- **Fixed rules, no learning.** If a rule is wrong, edit `Resources/rulebook.json`. The
  app will never quietly decide a rule is not for you.
- **No network code in the client. Not stubbed — absent.**
- **Never auto-submit** a handoff. The user reads what is about to be sent.
- **A window is identified three ways** — lone window, unique title, same rectangle —
  because the Accessibility API and ScreenCaptureKit disagree about titles.
- **Only restore a clipboard you still own.** A restore is a write.
- **The mascot is Doug — a hermit crab in a dead CRT, and the screen is his face.**
  Original character by design. `Doug.dc.html` is the source of truth for how he looks;
  `DougSprite.swift` copies its pixel grids verbatim rather than exporting images, so the
  two can't drift. The icon is generated from the same sprite.
- **Native Swift, distributed outside the Mac App Store.** The sandbox forbids the
  Accessibility API this depends on.
- **SwiftPM, not an `.xcodeproj`.** Command Line Tools build, sign, notarise and staple
  without Xcode.

## Conventions

- ⚠️ marks an unvalidated assumption or a decision needing external verification.
  Preserve the marker until it's actually resolved.
- **Three files, three jobs.** `CLAUDE.md` routes and rarely changes. `HANDOFF.md` is
  rewritten each session and is the only description of the present. `NOTES.md` is
  appended to and explains why.
- **`HANDOFF.md` and `parking-lot.md` are not in the repo, on purpose.** They describe
  one person's machine and one week's work, and are not intended for publication. They live on disk
  and are ignored. Anything in them that turns out to be about the *code* belongs in
  `NOTES.md` instead, where everyone can read it.
- `AGENTS.md` is a generated mirror of this file. Edit `CLAUDE.md`, then copy it across
  with the header line swapped.
