# The handoff

The whole app. Everything else is a way to start it.

## Two entry points, one flow

1. **⌥Space**, on whatever window you are looking at.
2. **Double-clicking Doug**, which does the same thing without the keyboard.

## The flow

### 1. Photograph the window, never the display

A full-screen grab sweeps in whatever else is open, which is both a privacy problem and
a worse prompt. Screen Recording is asked for on first run, and a denial is not a
failure — the handoff continues as text.

**Which window, exactly.** Three tests, narrowest first, because each one fails on a
different kind of app and any one alone leaves a hole:

1. **One window is not a choice.** A single on-screen window is the one the user is
   looking at, and nothing could be confused with it. No agreement required.
2. **A unique title match.** Works whenever the two APIs agree on the string, which for
   some apps they do.
3. **The same rectangle.** A window is in exactly one place, and both APIs report a
   frame. Compared as overlap rather than equality, since they round differently.

If none resolves, the handoff continues without a screenshot rather than photographing
something the user did not mean to share.

⚠️ The title comes from the Accessibility API and the window list from ScreenCaptureKit,
and **the two do not report the same string for every window** — a browser handoff could
never take a screenshot while titles were the only test. Which test identified the
window is logged.

### 2. Show it to its owner, and ask what they want

The screenshot appears at a readable size before anything is staged or opened, with an
editable prompt beside it. Include it, send text only, or cancel — each reachable from
the keyboard, since the flow begins with a keyboard shortcut.

**The prompt field is the point.** The app knows nothing about your work beyond a picture
of it. A canned line pretending otherwise wastes the first message of the conversation,
so the default is a starting point you can replace in the second before it sends.

**And the asking can be turned off, from the dialog doing the asking.** A confirmation
answered the same way every time is not a safeguard, it is a second keystroke. "Don't
ask again" records the answer just given. The menu keeps a tick to bring it back,
because a preference you can set and not clear is a trap rather than a setting.

### 3. Stage the clipboard, and only ever restore one you still own

⚠️ **Save and restore the user's existing clipboard.** Silently destroying someone's
clipboard is a small betrayal that people notice.

**Only restore a clipboard you still own.** The snapshot is taken before the destination
opens, and a cold launch is seconds long — long enough for the user to copy something of
their own. Every write and every restore checks the change count first, and a payload
that lost the race is offered as an explicit copy button instead. **A restore is a
write**, and deserves the same permission check as the write before it.

### 4. Open the destination and paste into *that* process

Wait for the process that was actually launched, not for any app to be frontmost.
`NSWorkspace` reports the pid it opened, including the user's real default browser, and
every synthesised event is posted to that pid.

Then check, immediately before each payload: still trusted for Accessibility, still that
pid in front, still own the clipboard, still an editable field focused. A handoff is
several seconds of waiting and the user is free to move during them.

**A web fallback never receives synthesised keystrokes.** A browser being frontmost says
nothing about whether the page has loaded or the composer has focus, and the new-chat
shortcut means something else entirely in a browser. Web handoffs open the page, keep the
payload, and ask for an explicit ⌘V.

**Posting a paste event is not proof of delivery.** The reported status is "paste
requested". That honesty belongs in the status and not on screen — an earlier build
raised a panel after every successful handoff, which turned one gesture into two
dismissals. Recovery appears only on the paths that leave someone holding something.

### 5. Never auto-submit

The prompt lands in the composer, filled in, **not sent**. The user reviews the draft and presses Return themselves. The receiving app may upload
pasted attachments before submission; its privacy settings apply. A screenshot may contain something they
would not choose to send, and a product that presses send for you is a product you stop
trusting with your screen.

## Failure handling

| Failure | Behaviour |
|---|---|
| Screen Recording denied | Text-only handoff, offered again in the review, no nagging |
| Destination app not installed | Web fallback, explicit paste |
| Destination won't open at all | Clipboard plus recovery panel, screenshot included |
| Target never comes frontmost | Clipboard, and say so |
| Focus, trust or clipboard changes mid-flight | Stop before the next event, offer manual paste |
| Several windows, none identifiable | Carry on without a screenshot, and say so |

The clipboard is the universal fallback: **even in total failure the content is one ⌘V
away**, and the user is never left with a broken interaction and no recourse.

## What is deliberately absent

No history, no database, no counters, no network. The app holds a screenshot for the
seconds it takes to hand it over, and a recovery payload for five minutes when something
went wrong. Preferences and diagnostic messages remain. Manual clipboard copies and copies retained
by the destination are outside that in-memory expiry. See READ-ME-FIRST.md for privacy details.
