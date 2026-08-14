# AI-slap

A macOS menu-bar app with a desktop mascot that watches which app you're in, notices when
you're doing something by hand that AI could do, interrupts you about it, and hands the
task to Claude in one gesture.

**This repo currently contains a specification only. No code has been written yet.**

## Start here

Read [`README.md`](README.md) first, then the docs in order. `docs/02` (detection) and
`docs/04` (mascot) carry the most load-bearing technical detail.

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
- **Never auto-submit** a handoff. The user reads what's about to be sent.
- **The north star is accepted interruptions, never interruptions fired.**

## Open questions — marked ⚠️ throughout the docs

1. Are window titles accurate enough alone? **Phase 0 answers this with data.** Don't
   build past it without running the spike — see `docs/08`.
2. Mac-only caps the enterprise market. Windows client, and when?
3. Does the goose open doors or close them with real buyers?
4. Pricing in `docs/01` is a placeholder, not validated.
5. AI deep-link URL parameters change — verify against vendor docs at build time.

## If you're starting to build

The next step is **Phase 0 in `docs/08`**: a menu-bar app that logs bundle ID, window
title, and dwell time to local SQLite. No mascot, no interruptions, no backend. It exists
to answer question 1 above before anything else gets built.

## Conventions

- Specs live in `docs/`, numbered. Keep them updated as decisions change — a stale spec
  is worse than none.
- ⚠️ marks an unvalidated assumption or a decision needing external verification. Preserve
  the marker until it's actually resolved.
