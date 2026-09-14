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
  Obsidian vault whose window title never changed read as continuous AI use.
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

### The nudges were rare for a reason nobody had measured

Chen asked why nudges were so infrequent. The first answer given was wrong, and the way it
was wrong is worth keeping.

**The wrong answer:** the raw log shows his longest single sit on one email in a week was
81 seconds, against `email.message.dwell`'s 90-second threshold — so the rule could never
fire. Checked against the data, confidently stated, and false. The engine never uses the
rulebook's number: `Personalizer.dwellThreshold` replaces it with the person's own p85.
His real bars are 46s for email, 79s for chat threads, 104s for docs. Reading the data the
code consumes is not the same as reading the code path that consumes it.

**The real answer.** Twenty-two moments in that week cleared their learned bar. Six nudges
fired. So thresholds were not the constraint — sixteen qualifying moments were killed
*after* qualifying, by the confidence gate:

```
adjusted = confidence × trustMultiplier(rule) × receptivityMultiplier(hour)
```

`trustMultiplier` is a posterior over that rule's own accepted/dismissed record, clamped
to [0.4, 1.6]. Chen's record is 3 accepted against 23 dismissed, which puts every rule at
or just under the firing threshold even on the pushiest setting. `chat.thread.dwell`
computes to **0.346 against a 0.35 bar**. It is losing by four thousandths.

**And most of those 23 dismissals were never dismissals.** `NudgePanel.Response.ignored`
— the five-minute timeout — was recorded as `.dismissed`, so a panel that appeared while
he was mid-sentence and one he deliberately turned down were the same row in the database.
Silence was training the product to stop talking, and no query could tell the two apart
because the distinction was destroyed at write time.

That is the most expensive bug found in this product so far, and it is four lines of enum.

`ignored` is now its own outcome. It is excluded from the trust posterior entirely — an
unanswered panel is evidence about the *moment*, not about the rule — and it feeds the
consecutive-dismissal backoff at half the weight of a real refusal, so a rule nobody ever
engages with still goes quiet, it just takes twice as much of it.

**Caveat that matters:** the fix only applies going forward. The 23 historical rows stay
`dismissed` and stay inside the 60-day tally window, so trust recovers slowly unless the
outcome history is cleared. That is the user's data and the user's call.

### Frequency, not duration — the shape no rule could see

The same log said something the rules had no vocabulary for. Chen touched chat threads 103
times in a week, averaging 52 seconds. Email surfaces 28 times, averaging 14 seconds. Every
rule in the book asks *"have you been sitting here a while?"* and the answer is always no —
not because he isn't grinding away by hand, but because his grinding is spread across
dozens of short returns rather than one long sit.

`surface.returns` counts returns to the *same* surface inside a window, each visit shorter
than a ceiling. Glances are excluded at the bottom on the usual reasoning, and long sits at
the top, so it cannot fight the dwell rules over the same moment.

The awkward part was arming it. `bestRule` picks the single highest-confidence rule
claiming a context, so on an email `email.message.dwell` wins at 0.80 and the returns rule
is never asked — which is exactly backwards, since email is where returns are the only
signal available. A returns rule is therefore armed *alongside* the winner rather than
instead of it. Both still pass every gate, and the already-nudged-about-this set stops the
two doubling up.

Backtested against Chen's week, a threshold of 12 returns in 90 minutes would have fired on
two surfaces. That is two or three extra nudges a week, not a transformation, and it should
be described that way. The trust fix is the bigger lever by far.

### Five outings instead of one

Chen: "the movement of the guy on the screen is nice, but he's doing the same thing every
time. that's boring. either no movement or variable movement."

The wander was one routine — walk one direction for a few seconds, come back. A wander is
now a short script of beats (walk, pause, look, turn) drawn from five shapes with speeds
and durations randomised inside each. One shape involves no travel at all: he turns, looks
around, and settles. That one does the most work, because it breaks the assumption that
Doug moving means Doug going somewhere.

### Two build lessons, cheap to learn twice

`codesign` blocked on a keychain prompt that only exists because the signing identity's
partition list had lapsed — the gotcha `scripts/make-signing-identity.sh` was written to
prevent. It presents as a hung build with no output.

Worse, deleting the leftover `AISlap.cstemp` by hand while `codesign` still held it
produced a bundle that passes `codesign -v` on disk and is then `SIGKILL`ed at launch with
`Code Signature Invalid`. **A valid signature on disk is not the same as valid pages at
load.** The fix is `rm -rf build` and a clean rebuild; there is no partial repair.

### The worst nudge this product has fired, and the one-line reason

Chen was working in ChatGPT and got a nudge telling him to hand his work to AI. Screenshot
and all. `surface.returns` had counted thirteen returns to a surface called "ChatGPT" and
interrupted him inside it.

`ChatGPT.app` ships as **`com.openai.codex`**. The rulebook asserted `com.openai.chat`,
which is not installed on any machine checked — so the native ChatGPT app was never an AI
context, the amnesty never applied to it, and `interruptedSignatures` never cleared there.
The same wrong id sat in the `destinations` list, meaning anyone choosing ChatGPT as their
handoff target would have silently fallen through to the web adapter with a working app
sitting in `/Applications`.

**The rule was innocent.** Nothing about `surface.returns` was wrong; it was simply the
first rule capable of reaching a surface that had been mis-classified since the rulebook
was written. Every dwell rule needs a long sit, and nobody sits in ChatGPT for 79 seconds
without typing — which is exactly why the defect could sit there for months looking like
silence.

Two fixes, and the second is the one that matters:

1. The id is corrected in both places.
2. **Every configured destination's bundle id now counts as an AI context, derived rather
   than listed.** A hand-maintained list will drift again — vendors rename, ship second
   apps, fork. But the app you hand work *to* can never be a place you are failing to use
   AI, so this particular absurdity is now structurally impossible instead of a
   list-maintenance problem.

Auditing the rest of the rulebook against `mdfind` found nothing else wrong for the apps
installed here. Worth doing on any bundle id before asserting it: `mdfind
"kMDItemCFBundleIdentifier == 'x'"` settles in a second what a plausible-looking string
cannot.

### ⚠️ Slack huddles are not suppressed, and the fix is not obvious

Found during the same audit. The conferencing list carries
`com.tinyspeck.slackmacgap.huddle`, but a huddle never becomes the frontmost *application*
— Slack is `com.tinyspeck.slackmacgap`, and that is what the detector sees. So Doug does
not vanish during a huddle, which is precisely the docs/04 scenario described as the
anecdote that kills the company.

The obvious fix is wrong. Adding `com.tinyspeck.slackmacgap` suppresses Slack entirely,
all day, and Slack is also a legitimate nudge surface — `chat.thread` matches it. Trading a
working rule for a suppression that fires constantly is a bad deal.

Doing it properly needs either the huddle window's title or camera/mic in-use state, and
the latter is the deferred `AVCaptureDevice` work docs/04 already flags. Left alone
deliberately, and marked, because it is a decision rather than a bug. **Until it is
resolved, ⌥⌘G before any call.**

Same shape, same section: `com.google.Chrome.app.meet` only matches Meet installed as a
Chrome app. Meet in an ordinary tab reports as Chrome and does not suppress.

---

## The review was written against a clone five commits behind

**The most expensive thing about this milestone had nothing to do with the code.** An
external review and a full implementation — the privacy and handoff fixes, sixteen
passing tests — were produced against `~/Documents/GitHub/ai-slap`, which is where
GitHub Desktop puts things and which had not been the working copy since Doug landed.
Every file the review touched had moved underneath it. What should have been a merge
became a port.

Nothing about the diagnosis was wrong; all of it applied. But `AppDelegate`,
`Handoff` and `AIDestination` had all been rewritten in the meantime, so the fixes had
to be re-grafted by hand and the tests re-run against code they had never seen.

**The check that would have prevented it takes five seconds:** `git remote get-url
origin` plus `git log -1`, and a look for a second clone of the same remote. A path
someone hands you is evidence of where they last looked, not of where the truth is.
This repository now says in `CLAUDE.md` that the workspace copy is the only one.

## A paste event is not a paste

The old `Result.pasted(hadImage:)` was a lie of exactly one word. The app posts a ⌘V to
another process and has no way to learn what happened to it — whether a composer had
focus, whether the app was listening, whether anything appeared. Reporting "pasted"
meant the log agreed with itself while the user looked at an empty box.

It is now `pasteRequested`, and the recovery panel holding both payloads stays up for
five minutes. This is a smaller change than it looks and a more important one: a product
that overstates what it knows in the one place the user can check is teaching them to
discount everything else it says.

## The clipboard race is on the *other* side of the open

Saving and restoring the clipboard is in the spec and was implemented. The gap was that
both the write and the restore assumed nothing had happened in between — and a cold app
launch is several seconds, which is plenty of time to copy something.

The fix is ownership: every staged transaction records the pasteboard's change count,
and a write or a restore that no longer matches is refused rather than forced. A payload
that loses the race becomes a copy button instead of an overwrite. **A restore is a
write**, and it deserves the same permission check as the write that preceded it.

## Doug celebrated things that had not happened

Found by porting, not by testing. His double-click was *the handoff*, so celebrating on
the gesture was honest. The new review step means the gesture now opens something you
can cancel — and he went on celebrating regardless, including on a failure alert.

The class of bug is worth naming: an optimistic UI is correct exactly until someone adds
a step that can say no. Doug now resets on cancelled, failed and permission-blocked
results. Anything that reacts before an outcome exists has to be re-read whenever a new
outcome is introduced.

## Long-term history was the user's call, and it reversed the spec

`docs/07` specified a rolling 30-day window. Chen asked for the opposite: keep it until
deleted, because the value of a usage log is the shape it takes over months, and this one
is the only evidence about whether the product works at all.

So retention is keep-forever by default and 30/90/365 are opt-in, behind a confirmation,
because choosing 30 days deletes everything older the instant you choose it. The titles
are what needed to disappear, not the history — and those are now separable, which is the
part the original spec conflated.

One consequence worth remembering: pruning used to run on launch, which is meaningless
for an app that stays open for a fortnight. It runs hourly now.

## The fix for a rare wrong answer was a constant no answer

Two hours after installing the privacy milestone, the first real ⌥Space produced a modal
apologising that it could not identify the window, and then a second panel to dismiss.
One gesture, two boxes, no screenshot. Both were introduced by the fixes, and both were
over-corrections of real findings.

**The capture.** The review found that capture could silently select an unrelated window,
which was true: the old code preferred a title match and otherwise took the app's largest
window. The fix required a unique exact title match and removed the fallback. But the
title the detector holds comes from `AXTitle` and the window list comes from
ScreenCaptureKit, and **those two APIs do not report the same string for the same
window** — so the match never succeeded and a browser handoff could never produce a
screenshot.

Worth separating: the danger is *substituting one window for another*, and that is only
possible when the app owns more than one. One window is not a choice. The rule is now
"one window needs no agreement; several need a unique title match, or no screenshot" —
which refuses exactly the case the reviewer was worried about and nothing else.

The debugging is the reusable part. Titles were being read fine (`has_title` was 1 on
every relevant row), the process ids matched, and a six-second sample showed no title
drift. Eliminating those left the string comparison as the only thing that could fail,
without ever reading the two strings side by side — the shell could not, because it is
not trusted for Accessibility. **Elimination against the app's own recorded data beat
guessing at the mechanism**, and two of the three hypotheses it killed were mine.

**The panel.** "Posting a ⌘V is not proof it landed" is correct, and it was expressed as
a floating panel after every handoff — including the ones that worked. A caveat the user
has to clear by hand is a caveat charged to them. It belongs in the reported status,
where it already was. Recovery now appears only when someone is actually left holding
something.

The general shape, and it is the second time this milestone: **a fix aimed at a rare
wrong answer that produces a constant absent answer is a worse product.** Ask what the
failure costs when it fires, then ask how often the correct path now fails. Doug
celebrating handoffs that did not happen was the same mistake pointing the other way.

## Three tests beat one, and the confirmation had to be optional

Chen's reply to the single-window fix was "couldn't you have both of these in place, belt
and suspenders?" — and he was right, for a reason the fix had skipped over. Obsidian
*had* captured, with two windows open, which meant the title test genuinely works for
some apps. Narrowing the rule to "one window only" would have thrown that away to solve
the browser case.

So the rule is three tests, narrowest first: a lone window, then a unique title, then the
same rectangle. They fail on different apps, which is exactly the argument for keeping
all three — a single test is a single point of failure, and the cost of a second one here
is a handful of lines.

**Match by geometry rather than by name where you can.** A name is a string two APIs
format differently. A window is in one place, and both report a frame. Compared as
overlap rather than equality, because they round to points differently and a shadow
should not lose a window that is plainly the same one. Which test won is logged, since
the honest position is that this has been verified on one Mac.

### A confirmation you always answer the same way is a keystroke, not a safeguard

The screenshot review exists because the app is holding a photograph of your screen. That
justification is real and it does not survive being charged twenty times a day. Chen asked
for the toggle from inside the dialog, which is the right place: the moment it annoys you
is the moment you know your answer.

Two details that make it a setting rather than a trap. It records **the answer just
given** rather than guessing which one was meant, so "don't ask again" after *Text only*
does not silently start attaching screenshots. And the menu keeps a tick to turn it back
on — a preference you can set and cannot clear is a one-way door out of the only privacy
control this flow has.

Every button in that dialog now answers to the keyboard too. The flow starts with a
keyboard shortcut; making the user reach for the mouse to finish it was friction nobody
chose.

**One trap for anyone testing this.** `HandoffRecovery.review` opens a real modal, so a
test that reaches it does not fail — it hangs forever waiting for a click. Set the
preference before calling it. A mutation that deleted the preference check proved the
test was load-bearing by hanging the suite, which is a signal, but not a pleasant one.

### Verified: position is what identified the window, on the first real try

Chen's Finder test, 13:02 on 11 September. Finder had three windows open and **two of
them were both called the same thing** — so the title test could not resolve it,
and with three windows the lone-window test did not apply. The capture succeeded anyway,
on window 14296 at (452, 474), and not on its identically named twin at (423, 445).

Only the rectangle could have picked that. So the geometry test works on a real machine,
the two APIs do agree about frames, and the belt-and-suspenders argument paid for itself
on the first handoff after it shipped: with titles as the only fallback, this exact
handoff would have refused.

Two duplicate titles in one app was also not a hypothetical edge case. It was just what
was open.

**The evidence came from ScreenCaptureKit's own logging, not ours.** The `NSLog` lines
added for exactly this purpose never reached the unified log — the app's own messages do
not appear under a `processIdentifier` predicate even with `--info --debug`, while every
framework message does. Worth replacing with `os.Logger` and an explicit subsystem before
relying on app logs again. What worked instead: filtering the app's log for ScreenCaptureKit
entries, reading the `frame=` on the `SCWindow` it selected, and matching that against a
live window dump.

---

## The product was the launcher all along

Four weeks of the author's own data, with idle time stripped out:

| | |
|---|---|
| Time already inside an AI app | 46.7 hours, 59% |
| Everywhere else | 32.1 hours, 41% |
| Interruptions fired | 31 |
| Accepted | 3, one every nine days |

And the 41% was mostly browsers, Slack, Messages and Zoom — reading and talking, not
manual work waiting to be handed off. The detection layer was hunting for a moment that
rarely happened to the only person running it.

**The tell was the text-only prompt.** Chen's words: "it just says here's what I'm
working on, can you help? What's the point of that at all?" He was right, and the reason
was structural rather than a copywriting miss. Every prompt in the app was written
assuming a picture was attached. Strip the screenshot and each one becomes a sentence
about something the AI cannot see.

Which exposes the ceiling: **everything the app knew about your work was an app name and
a window title.** The nudge copy was generic because the classifier only knew "a
document". The prompt was generic for the same reason. The screenshot was carrying the
entire payload, and the app never understood it — it only forwarded it.

So detection was the trigger and the screenshot was the product. Once that is true, the
rules engine, the personaliser, the log, and every piece of privacy machinery built to
protect that log are all scaffolding around a thing that was never load-bearing. About
3,000 lines came out.

**The generalisable part:** when a feature's output is hollow, check whether the hollowness
is a bug in that feature or a report on how much the system actually knows. A canned
prompt with nothing in it was the second kind, and no amount of rewriting the line would
have fixed it.

### Privacy machinery is a function of what you keep

The removed version had migration code, `secure_delete`, `VACUUM`, retention windows, an
export, a delete-all that cleared nine different things, and a spec section arguing about
which of them counted as personal data. All of it was real and all of it existed because
the app kept a log.

Keeping nothing deleted the entire category. There is no retention setting now because
there is no retention, no delete button because there is nothing to delete, and no
argument about window titles because none are written down. **The cheapest privacy
control is not collecting it**, and that is a product decision rather than an engineering
one — which is why it sat unexamined for months while the engineering around it got more
elaborate.

### An app for other people needs things an app for yourself never did

Shipping the same binary to ten strangers surfaced work that four weeks of solo use never
did, none of it clever:

- **A first run that explains itself.** A menu-bar app needing two system permissions
  before it can do anything is the easiest kind to give up on — it launches, shows an
  icon, and appears broken.
- **An icon.** It had been running with the blank placeholder for months, and nobody
  noticed because the author never looked at the Dock. Generating it from `DougSprite`
  rather than drawing one keeps it from drifting from the character, the same argument
  the sprite already makes against exporting PNGs.
- **A note for the recipient**, because an unsigned app is refused by Gatekeeper with a
  message that sounds like a virus warning and is actually a statement about a
  certificate.
- **The $99 Developer ID**, which is now the whole distance between working and
  shareable.

### ⚠️ You cannot check your own UI on a sleeping Mac

This session built a new onboarding flow, a new dialog and a new menu, and saw none of
them. The display was asleep: `screencapture` returns pure black, and ScreenCaptureKit
refuses to composite individual windows.

What still worked was asking the window server what the app had open — two windows, one
390×372 and one 100×68, which is an alert and a crab. That proves it launched, did not
crash, and put the right things on screen. It proves nothing about whether they look
right. Worth knowing the difference before reporting either one.


## Setup must survive leaving the app

First-run setup previously marked itself seen before either permission was granted.
Choosing Accessibility exited the dialog and relaunch skipped Screen Recording. Setup now
persists a separate pending state, resumes after a grant or relaunch, and lets Skip for
now stop the prompts. Both permission orders and explicit reopening have regression tests.
The menu exposes screenshot setup and flags either missing permission.

The release is explicitly Apple Silicon, includes its guide, and reports its real version.
Notarization must archive the same app after stapling: rerunning the build deletes the
ticket. Packaging now has a notarize flow and a separate repack mode. The privacy guide
also distinguishes app memory from clipboard copies and content received by an AI service.


## One download for both Mac architectures

Universal packaging builds arm64 and x86_64 separately, combines them with lipo, strips
local debug paths, and then signs the resulting app. Passing both --arch flags to a
single SwiftPM invocation works with Xcode but invokes xcbuild and fails on a machine
with only Command Line Tools. Separate builds preserve the documented setup requirement.
Packaging and repacking require both slices. Compilation is not an Intel runtime test;
the release and install guide state that Intel runtime testing is pending.
