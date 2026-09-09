# NOTES — why the code is the way it is

Engineering notes and hard-won lessons. Nothing here describes the current state (that's
[`HANDOFF.md`](HANDOFF.md)) and nothing here is a rule to follow (that's
[`CLAUDE.md`](CLAUDE.md)). This is the reasoning behind decisions that would otherwise
look arbitrary, and the bugs that cost real time.

Append to this one — unlike `HANDOFF.md`, old entries stay useful.

---

## Why the rulebook and the Personaliser are separate

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

## Where the code knowingly departs from docs/

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

## The docs/08 gate was skipped — what that costs

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

## Bugs that cost a day, so nobody repeats them

Each of these produced a bug that looked like something else entirely.

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



## What eleven days of real use taught us — 2026-08-25

One user, ~3,000 sessions, 17 nudges. Everything below is n=1 and should be read that
way: the formal `docs/08` gate was skipped, so nothing here separates "true of the
product" from "true of this person". That distinction is the whole reason to get more
users on it.

### Acceptance was 27%, and the average hid everything

Four useful out of fifteen resolved — just above the ≥25% target in `docs/03`. But per
rule: `chat.thread` 2/5, `doc` 1/4, `search.repeated` 1/1, `email.message` **0/5**.

Strip the one bad rule and it's 4/10. One rule was generating a third of all
interruptions and had never once been right. **Report per-rule acceptance, never the
average** — the average is what lets a broken rule hide inside a healthy product.

### The backoff had no teeth

`email.message` was dismissed three times running, went quiet for 24 hours as designed,
then came back and was dismissed again. And again. Five for five over six days.

The escalation everyone assumes is there was not: a flat 24 hours, forever, and a hard
mute that needed 12 resolved outcomes — a bar a low-volume rule never reaches. So the
single mechanism protecting against the product's most likely cause of death did almost
nothing. Fixed to 3 → a day, 5 → a week, 8 → a fortnight.

**Owner's constraint, and it is a good one:** no rule ever retires itself permanently.
What someone works on changes, and a rule that was useless in August may fit in October.
Permanence is the user's decision alone, and reversible.

### We were teaching it with noise, and it changed the conclusions

A notification tab — "Google Drive messaged you" — accounted for 249 sessions averaging
3.6 seconds. Hundreds of sub-5-second focus-steals were being fed into the dwell
percentiles the Personaliser learns from.

Excluding them moved this user's p85 for email from **10s to 46s**, and for docs from
72s to 98s.

That matters beyond the numbers, because the 10s figure had been used to conclude that
this user "never lingers on email, so no threshold can work" — a confident, structural,
product-level claim. It was substantially an artifact of our own measurement. The rule
had been firing at the 20-second floor because the contaminated data made the learned
figure look smaller than the floor.

**The lesson is not "filter noise".** It is that an analysis of user behaviour is only as
good as the instrument, and a plausible story explained the corrupted numbers perfectly
well. Check the instrument before concluding something about the person.

### Dwell finds lingering; a lot of real work accumulates instead

Of ~24 hours of non-idle time: 11.3 in AI, 9.5 in surfaces no rule watched at all, and
4.1 across every matched category combined. The unwatched time was consent-banner config
(30 visits), a tag manager (83 visits), analytics dashboards — fiddly repetitive work,
none of it a long sit, all of it the kind of thing AI is good at.

Every rule asked "have you been here a while?" Nothing asked "how much of today has this
eaten?" Hence `surface.grind`, which carries no site list so it generalises to whatever a
given person grinds in.

`task.recurring` from `docs/03` would *not* have caught it, incidentally — the
cross-day repeats were dominated by notification tabs and New Tab. The work was bursty,
not habitual.

### Volume was never the constraint

Budget was set to 15/day. Actual: 2.4/day. Per-rule cooldowns bind long before the daily
budget does, so tuning the budget in either direction does nothing. If volume needs
changing, cooldowns are the lever.

### Still open

The user is a heavy AI user, which may make them the wrong test case entirely — roughly
half their observed time already *is* AI, and their manual moments are short interleaved
gaps rather than long sits. Whether the nudges are *useful* to such a person remains the
central unanswered question, and it cannot be answered with one log.

## Doug: the design file is the source, and the code copies it

The mascot arrived as a design canvas — `Doug.dc.html` — rather than as a sprite sheet: a
hermit crab living in a dead CRT, with the screen in his shell as his face. That choice is
worth writing down, because it decides the shape of the code.

**One shell plus a set of tiny 14×7 faces is the entire character.** Mood is a face swap
inside a fixed body, not a redraw, which is why six emotions cost six seven-line strings
instead of six sprite sheets — and it is why the `docs/04` cost line for an animator no
longer has to be paid before anything can ship.

`DougSprite.swift` therefore holds the same pixel-grid strings the design file paints
from, copied verbatim rather than exported to PNGs. Exporting is simpler code and it was
the wrong trade: the moment either side is edited the app and the canvas disagree and
neither is authoritative. As text, an edit in one is a copy-paste into the other, and the
palette recolours the whole character from three constants.

`scripts/design-preview.sh` renders the sprite and the bubble offscreen from the shipping
source. Both are drawn rather than composed from system controls, so "does this still look
like the design" is not a question that can be answered by reading the code, and the first
build of the bubble got it wrong in a way review would not have caught — the four
response buttons hugged their titles and came out four different widths, which reads as
three afterthoughts beside a primary rather than as four equal answers.

### The tier ladder is driven from outside the engine

`docs/04` wants tier 1 — Doug stopping and turning to look at your window — to be the
overwhelming majority of interruptions. That cannot come from the fire path, because by
definition it has to happen *before* anything fires.

So the engine gained exactly one read-only method, `dwellProgress(for:since:)`, and the
ladder lives in `AppDelegate` alongside the menu refresh that was already running. Two
consequences worth keeping:

- **The stare reads the same gates the nudge does.** He never looks up for something that
  is suppressed, muted, resting on a backoff, or over budget — the stare would be a
  promise the engine has already decided not to keep.
- **No second timer.** A resident mascot earning its own polling loop is precisely the
  battery complaint `docs/04` sets budgets to avoid.

Tier 0 is asleep rather than idling: no display link, no paused animation loop, no timer
at all. A frame timer exists only while something is actually moving and is torn down when
it stops. Tier 1 is one repaint followed by nothing, which is a pleasing property for the
tier that is meant to be almost all of them.

### Two things the ladder does not do yet

- **A drag onto a window hands off the *frontmost* window, not the window under Doug.**
  Reading the window beneath a point needs `CGWindowListCopyWindowInfo`, which needs
  Screen Recording — the permission this app has refused since `docs/02`. In practice the
  frontmost window is almost always the one being pointed at, but "almost always" is doing
  real work in that sentence and it will be wrong on a multi-window desktop.
- **The hit area is the sprite's bounding box, not its alpha.** `docs/04` suggests a
  hit-test mask against the sprite's alpha; instead the window is sized exactly to the
  sprite, so every pixel outside Doug belongs to the app underneath because there is no
  window there. The gap is the transparent corners *inside* that box, which swallow a
  click meant for whatever is behind them. At a 34×22 sprite this is a few dozen points.

### Silkscreen is not bundled

The design file pulls Silkscreen from Google Fonts. Shipping it means committing a binary
asset and carrying its licence, so the buttons ask for `Silkscreen` by name and fall back
to monospaced system text at small size with tracking. If the font is ever installed the
app picks it up with no code change. The near miss is visible but it is a near miss.

### The design file's palette is right for paper and wrong for a desktop

Doug went on screen for the first time and half of him was missing. The canvas paints him
on `#EFE8DC`, so his silhouette is near-black ink and reads beautifully. Against a dark
desktop that silhouette *is* the background: the outline and all four legs disappeared and
he read as a floating pink CRT with no body.

The fix is `Doug.Palette.onDesktop` — the same three colours with the two flat ones
exchanged, cream silhouette on a dark bezel. The bubble still uses `.standard`, because a
bubble carries its own paper with it and a crab does not.

It is deliberately **not** switched on the system appearance. Doug cannot see the wallpaper
behind him without Screen Recording, which this app refuses, so following light mode moves
the failure to a dark wallpaper in light mode rather than fixing it. One look, chosen for
the ground he actually stands on.

Worth generalising: **the design file is authoritative about the character and not about
its context.** Everything in `Doug.dc.html` sits on a page. Nothing in the app does.

### Coming down a tier is a walk, not a teleport

The first build dropped Doug to tier 0 wherever the nudge had left him — halfway across
the screen after a scuttle, or perched on a window frame after hard mode. Reading the
code that looks like "the tier reset correctly". Watching it, he is abandoned mid-screen.

`goHome()` walks him back on both axes, because tier 4 leaves him partway up a window and
returning along x alone would strand him in mid-air. He wears `.content` on the way rather
than `.sleep`, since a sleeping face on a moving crab reads as a bug.

The trigger is a context change, which is the same signal that resets the ladder — so he
heads home when you switch to *anything*, and the AI apps that prompted the request are
covered by the rulebook's own list rather than by a special case for one of them.

### Correction: no silhouette colour survives both, so he carries a keyline

The entry above — swapping Doug's two flat colours so he reads on a dark desktop — was
half a fix, and the other half showed up within a day. Chen put him on a white window and
the cream silhouette disappeared exactly as the near-black one had against the desktop.

The mistake was in the framing, not the colour. **A desktop mascot is almost never on the
desktop.** He stands on top of whatever window you are working in, and those are white as
often as not. Choosing a silhouette colour is choosing which half of the day he is
invisible for, and following the system light/dark setting only describes the desktop —
the surface he is least often standing on. Reading the actual pixels behind him would need
Screen Recording, which this app refuses.

So he carries both colours instead: the design file's ink silhouette exactly as drawn,
wrapped in a one-cell paper keyline. One of the two always contrasts, on any backdrop,
without needing to know what the backdrop is. `Palette.onDesktop` is gone and the sprite
is back to the canvas's own palette, which is a happier place for it to be — the halo is
an addition to the character rather than a change to it.

Two mechanical notes. The halo is a **ring**, not a fill: filling the silhouette and
drawing on top looks identical on a shape with no holes and swallows Doug's legs, which
have gaps the ring is meant to trace. And the sprite gained a one-cell margin on every
side (`haloPad`), because without it the keyline is drawn outside the view and clipped
away on three sides.

`design-preview.sh` now renders the sheet on a split dark/white ground, since a single
background can no longer answer the question.

### A wander needs a restoring force, or it is a random walk

Tier 0 woke Doug every 70–200 seconds, walked him in a random direction for a few
seconds, and stopped him wherever that ended. The next leg then started from *there*.
That is a random walk, and a random walk with nothing pulling it back does exactly what
random walks do: over an afternoon he drifted into the middle of the screen and sat on top
of the sentence Chen was writing.

The bug is invisible in a single leg and obvious after an hour, which is the whole
category. A wander is now a there-and-back — out, then home — and the outbound leg is
capped at `wanderRange` so he cannot reach the middle of the screen even once. Both halves
matter: the cap alone would still leave him parked wherever he stopped.

### Picking something up is not asking it to do something

docs/04's "the goose is the button" was implemented literally: a single click on Doug ran
a handoff, and so did dragging and dropping him. Both of those are also the gestures for
*moving him out of the way*. So nudging a crab off your own sentence took a screenshot of
your window and pulled Claude to the front, mid-thought. Chen's words: "clicking to move
takes a screenshot and breaks my workflow."

Now: drag moves him and does nothing else, and **double-click** is the handoff. The design
rule survives — every tier still terminates in one gesture to the handoff — it just is no
longer the same gesture as "get out of my way".

The cost is discoverability: double-click is not a guessable gesture on a wordless crab.
He carries a tooltip that names both gestures and the destination, which is the smallest
thing that could work. If the gesture turns out to go unused, that is the first suspect.

Doug also stays where he is put. Walking straight back to the corner would undo the move,
and moving him is usually a request for him to be somewhere else. The corner reasserts
itself at the next tier, which is soon enough.

### The destination was a property of list order, not a choice

`preferredDestination` returned the first natively installed entry in the rulebook. That
is indistinguishable from correct as long as everyone uses the app at the top of the list.
For anyone who works in ChatGPT or Gemini it silently pasted their window into an app they
do not use.

The rulebook already had the right shape — destinations are data, not code, so adding
Gemini and Perplexity was a data change. What was missing was a choice: a stored id
consulted first, a picker in the menu, and a question on first run. The old behaviour is
still the fallback, and deliberately: a chosen destination whose app has since been
uninstalled should degrade to something working rather than to a failed handoff and a
lost capture.

One bug fell out of looking at it. `newChatShortcut` was sent whenever the destination
defined one, including on the web fallback — where the frontmost app is a browser and ⌘N
opens a new *window*, so the handoff pasted into a blank tab that had never navigated
anywhere. It is now sent only when the native app was the thing that opened. This never
bit Chen because Claude's native app is installed; it would have bitten the first
Perplexity user immediately.
