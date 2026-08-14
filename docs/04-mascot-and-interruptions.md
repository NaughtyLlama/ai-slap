# 04 — Mascot & interruptions

The interruption layer is a desktop critter — in the spirit of
[Desktop Goose](https://samperson.itch.io/desktop-goose) — that lives on your screen,
watches what you're doing, and gets visibly annoyed when you do things by hand.

**This is not decoration.** It's the answer to nag fatigue, which is the risk most likely
to kill the product. A notification saying "you should use AI" is a nag people mute in
week two. A goose that side-eyes your half-typed email is a thing people screenshot and
send to their team.

## The one design rule that matters

**The goose is the button.**

- Drag the goose onto a window → that window is captured and handed to Claude.
- Click "ugh, fine" in its speech bubble → the handoff flow fires.
- Ignore it → it goes back to napping.

A mascot that only nags gets muted. A mascot that *does the work when you click it*
becomes the fastest path to the thing you wanted anyway. Every interruption tier must
terminate in a one-gesture path to the handoff — if a tier can't, it shouldn't exist.

## Rendering

A borderless, transparent, non-activating `NSPanel` with a SpriteKit view inside.

```swift
panel.styleMask         = [.borderless, .nonactivatingPanel]
panel.backgroundColor   = .clear
panel.isOpaque          = false
panel.hasShadow         = false
panel.level             = .screenSaver
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
panel.ignoresMouseEvents = true          // flipped false only over the goose's bounds
NSApp.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
```

Two of those flags are load-bearing:

- **`.nonactivatingPanel`** — the window never takes keyboard focus, so you keep typing
  into Gmail while a goose walks across it. Without this the app is unusable.
- **`ignoresMouseEvents = true`** everywhere except the goose's own bounds — otherwise
  you're swallowing clicks meant for the app underneath. Track the sprite's frame and
  toggle per-region, or use a hit-test mask against the sprite's alpha.

`.screenSaver` level plus `.fullScreenAuxiliary` is what lets the goose follow you across
Spaces and appear over full-screen apps. Without it the goose is trapped on desktop 1,
which defeats the purpose.

**Framework choice.** SpriteKit (`SKView`) for the character — sprite-sheet animation,
physics for the waddle, cheap. SwiftUI for speech bubbles and settings. This is another
reason the client is native Swift: an Electron app cannot do a transparent, click-through,
non-activating, always-on-top animated overlay without an unreasonable fight.

**Multi-monitor.** Walk between `NSScreen.screens`; handle
`NSApplication.didChangeScreenParametersNotification` for display connect/disconnect and
resolution changes. The goose should end up on the screen with the active window.

## ⚠️ Performance is a product requirement

A resident animated character that costs 40 minutes of battery gets deleted by lunch.
These are acceptance criteria, not aspirations:

| State | Budget |
|---|---|
| Idle (goose asleep) | **0% CPU** — `SKView.isPaused = true`, no display link, no timer |
| Ambient wander | < 1% CPU |
| Active interruption | < 3% CPU |
| Any state | never wakes the discrete GPU; no measurable `powermetrics` delta |

The goose genuinely sleeps. Not a paused animation loop — no render loop running at all.
Wake on rules-engine signal, animate, return to sleep. Add an automated performance test
in CI that fails the build on regression, because this will regress silently otherwise.

## The escalation ladder

Interruption strength scales with rule confidence and how long you've been ignoring it.

| Tier | Behavior | Interruption | Handoff path |
|---|---|---|---|
| 0 | **Ambient** — naps in a corner, preens, occasionally waddles | none | drag it onto a window |
| 1 | **Side-eye** — stops, turns, stares at your active window | peripheral guilt only | drag, or click |
| 2 | **Honk** — speech bubble: "you're typing that whole email by hand?" | dismissible | "ugh, fine" button |
| 3 | **Waddle over** — crosses the screen, pecks at the window, drops a note | mild | click the note |
| 4 | **Hard mode** (opt-in) — sits on your compose box, tugs the cursor | real | click the goose |

**Tier 1 is the highest-value interaction in the product and should be the overwhelming
majority.** It costs the user nothing, interrupts nothing, and peripheral-vision guilt is
startlingly effective — a character that stops and looks at you is impossible not to
notice and trivial to ignore. That combination is exactly what you want.

Tiers 3 and 4 are where products like this die. Constraints:

- **Tier 4 is opt-in only**, never reachable by escalation from default settings.
- Cursor tugging uses `CGWarpMouseCursorPosition` and is genuinely disruptive if it lands
  mid-click or mid-drag. Gate it: never during an active mouse button, never during text
  selection, hard-capped at once per hour, and always a small nudge rather than a capture.
- Any tier ≥3 must be individually disableable.

Escalation only occurs *within* a single sustained context. Ignoring a tier-1 stare for
another 90 seconds on the same email may earn a tier-2 honk. Switching apps resets to 0.

## Mood as the retention loop

The goose's mood tracks your AI usage across the session and week:

- **Content** → recent AI use, ambient napping and preening.
- **Restless** → a stretch of manual work, more pacing, more looking over.
- **Grumpy** → sustained manual work, visible sulking, faster escalation.
- **Delighted** → a handoff just landed. Brief celebration animation.

Streaks are expressed as goose mood rather than as a number, and the weekly report is
narrated by the goose ("I watched you write 41 emails by hand. I'm not angry.
I'm disappointed."). This is a far stickier loop than a dashboard nobody opens, and it
makes the report itself shareable.

## Suppression — must be near-perfect

**A goose appearing during a board demo is the anecdote that kills the company.** This
section gets its own test plan.

Hard suppression, goose vanishes instantly:

| Condition | Detection |
|---|---|
| Screen sharing or recording | conferencing bundle IDs running/frontmost + `AVCaptureDevice.isInUseByAnotherApplication` |
| Camera or mic in use | `AVCaptureDevice` in-use state |
| Presentation mode | Keynote/PowerPoint slideshow, full-screen video |
| macOS Focus / Do Not Disturb | Focus status |
| Panic hotkey | user-invoked, hides 30 min |
| Lock screen / screensaver | workspace notifications |

⚠️ **Reliably detecting that *another* process is capturing the screen is genuinely hard
on modern macOS.** There is no clean public API that says "someone is screen-sharing right
now." The practical approach is a conservative allowlist of conferencing bundle IDs (Zoom,
Teams, Meet in a browser, Slack huddles, Webex, Discord, OBS, QuickTime recording) plus
camera/mic in-use state, and **accepting false-positive hiding**. Hiding when you didn't
need to costs nothing. Failing to hide once costs the account.

Ship a **panic hotkey** (⌥⌘G by default) and a menu-bar hide, both instant, both
discoverable in onboarding. Users need to trust they can make it disappear in one keystroke
or they won't run it at all.

## Accessibility and taste settings

Non-optional, all three:

- **Reduced motion.** Honor `accessibilityDisplayShouldReduceMotion`. Offer **calm mode**:
  the goose never wanders, appears only to interrupt, moves minimally. Vestibular
  sensitivity is common and a wandering sprite is a genuine accessibility problem.
- **Mascot-free mode.** Falls back to plain `UNUserNotificationCenter` notifications with
  action buttons. Some people will hate the goose; enterprise will require this; and it's
  the headless path the rules engine already targets.
- **Screen reader behavior.** The goose is decorative — mark the panel
  `accessibilityElement = false` so VoiceOver doesn't announce a wandering bird. Speech
  bubbles, however, must be readable and their buttons focusable.

Plus ordinary taste controls: pushiness (three positions), quiet hours, per-rule mute,
mascot size, and which corner it lives in.

## Enterprise reconciliation

This is how the goose and the B2B buyer coexist:

| Setting | Individual default | Team default | Admin can |
|---|---|---|---|
| Mascot enabled | on | on | force off org-wide |
| Max tier | 4 (opt-in) / 2 | **2** | cap lower |
| Suppression list | standard | standard + custom bundle IDs | extend |
| Panic hotkey | on | on | not disable |

**Full goose for individuals, tamed goose at work.** The bet is that the individual
version drives the bottom-up adoption that gets you into accounts top-down sales wouldn't
reach — see the commercial risk in [08](08-roadmap-and-risks.md).

## ⚠️ IP: don't clone Desktop Goose

[Desktop Goose](https://samperson.itch.io/desktop-goose) (Samperson) and Untitled Goose
Game (House House) are both well-known existing products.

A goose as a concept isn't protectable. **A white goose that waddles around stealing your
cursor is squarely Desktop Goose's trade dress**, and that's the exact silhouette this
product would otherwise land on.

Requirements:
- Commission an **original character** — original art, original name, original signature
  behaviors. Do not reuse or trace Desktop Goose's sprites or reproduce its specific gags
  (the memes, the mud footprints, the dragged-in images).
- Don't use "Desktop Goose" or a confusable name in branding, the App name, or ASO copy.
- Get a written work-for-hire assignment from the animator covering all sprite assets.

⚠️ **A distinct animal would be more defensible and more ownable as a brand.** The goose
is funnier, and funny is a real commercial asset here — so this is a decision to make
knowingly rather than by drifting into it. Worth ten minutes with an IP lawyer before the
art is commissioned, since the art is the expensive part to redo.

## ⚠️ New cost line: an animator

The mascot introduces a cost that doesn't exist in the rest of the plan.

Roughly **10 behaviors × 4 directions** of sprite work for v1 — idle, sleep, walk, turn,
stare, honk, peck, celebrate, sulk, drag — plus speech-bubble art and the mood variants.

**The art quality *is* the product here.** Cheap mascot art reads as malware; that's not
an exaggeration, it's the actual first impression a user forms in three seconds. Commission
at the **start** of Phase 1, not as Phase 4 polish — it's on the critical path and it has
lead time that engineering doesn't.
