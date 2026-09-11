# 05 — Handoff

The handoff is what makes the interruptions tolerable. Without it the goose is a critic;
with it the goose is a shortcut.

## Three entry points, one flow

1. **Global hotkey** — ⌥Space by default, user-configurable. Works with no interruption
   pending, on whatever you're looking at. This is the "set a timer, screenshot it, drop
   it into Claude" quote made instant.
2. **Goose speech bubble** — clicking "ugh, fine" on a tier-2+ interruption.
3. **Drag the goose onto a window** — physical, discoverable, and the thing people will
   put in videos.

All three converge on the same six steps.

## The flow

### 1. Trigger

Register the hotkey with Carbon `RegisterEventHotKey` or the
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) package (which
wraps it and handles recorder UI). `NSEvent.addGlobalMonitorForEvents` is *not* sufficient
— it can't consume the event, so the keystroke also reaches the frontmost app.

### 2. Capture the active window

ScreenCaptureKit, scoped to one window:

```swift
let content = try await SCShareableContent.current
guard let window = content.windows.first(where: { $0.windowID == targetWindowID })
else { return }
let filter = SCContentFilter(desktopIndependentWindow: window)
let image  = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                        configuration: config)
```

⚠️ **This needs Screen Recording permission** — the one prompt deliberately deferred out
of onboarding. Request it **lazily, on first handoff only**, where the ask explains itself
("to send this window to Claude, I need to be able to see it"). Detection keeps working
without it; the app is never broken by a denial, it just loses the screenshot and falls
back to text-only handoff.

Capture the **window**, never the display. A full-screen grab sweeps in whatever else is
open, which is both a privacy problem and a worse prompt.

**Which window, exactly.** If the frontmost app owns one on-screen window, that is the
one — there is nothing it could be confused with. Only when it owns several does the
title have to agree, and if none does, the handoff goes on without a screenshot rather
than photographing something the user did not mean to share.

⚠️ The title the detector holds comes from the Accessibility API; the window list comes
from ScreenCaptureKit. **The two do not report the same string for the same window.**
Requiring them to match before capturing anything sounded strict and meant a browser
handoff could never take a screenshot at all. Matching titles is a tie-breaker between
several windows, and it is not sound as a precondition.

### 3. Build the prompt

From the matched rule's `promptTemplate` ([03](03-rules-and-nudges.md)), or a generic
"Here's what I'm working on — can you help me with this?" for a context-free hotkey press.

Templates are plain text with no interpolated content from the screen. The window title is
*not* injected — it's already been reduced to a category token and discarded, and injecting
it would leak exactly the content [02](02-detection-architecture.md) is careful not to keep.

### 3b. Show the capture to its owner first

*Added 2026-09-10.* A screenshot is shown locally, at a readable size, before anything
is staged or opened. Include it, send text only, or cancel.

This was not in the original six steps and it should have been. The whole product asks
for a permission that lets it photograph a window, and the only thing that makes that
bearable is seeing the photograph before it leaves. It also turns the screenshot
permission from a modal you meet in the dark into a choice attached to a picture.

### 4. Stage the pasteboard

Image + prompt text onto `NSPasteboard.general`.

⚠️ **Save and restore the user's existing clipboard.** Silently destroying someone's
clipboard is a small betrayal that people notice and resent. Snapshot before, restore
~2 seconds after the paste.

**Only ever restore a clipboard you still own.** The snapshot is taken before the
destination opens, and a cold launch is seconds long — long enough for the user to copy
something of their own. Restoring blindly would overwrite it, which is the same betrayal
committed at the other end. Every write and every restore checks the change count first,
and a payload that lost the race is offered as an explicit copy button instead.

### 5. Open the destination and paste

Open the target and wait for **that process** to become frontmost, not for any app to be.
`NSWorkspace` reports the pid it actually launched, including the user's real default
browser rather than whatever was in front when the URL opened, and every synthesised
event is posted to that pid.

Then check, immediately before each payload: still trusted for Accessibility, still that
pid in front, still own the clipboard, still an editable field focused. A handoff is
several seconds of waiting and the user is free to move during them; a ⌘V aimed at a
window that is no longer there types into whatever replaced it.

**A web fallback never receives synthesised keystrokes.** A browser being frontmost says
nothing about whether the page has loaded, the user is logged in, or the composer has
focus — and the destination's new-chat shortcut means something else entirely in a
browser. Web handoffs open the page, keep the payload, and ask for an explicit ⌘V.

**Posting a paste event is not proof of delivery.** The status the app reports is
"paste requested", never "pasted". Reporting a confirmed paste it cannot confirm is how
a product teaches people not to trust its other claims.

⚠️ **That honesty belongs in the status, not on screen.** The first build of it raised a
recovery panel after *every* handoff, successful ones included, so a one-gesture flow
ended in a box to dismiss. A caveat the user must clear by hand is a caveat charged to
them. The recovery panel is for the paths that actually leave someone holding something:
a destination that would not open, a focus change that stopped the paste, a web fallback.
On success, nothing appears.

### 6. Never auto-submit

The prompt lands in the composer, filled in, **not sent**. The user reads what's about to
be transmitted and presses Enter themselves.

This is non-negotiable for three reasons: a screenshot may contain something they'd not
want sent; auto-submit makes the app an exfiltration tool in the eyes of a security
reviewer; and the user needs to feel in control of a product whose entire premise is
nagging them.

## Destination adapters

Behind an `AIDestination` protocol, with the per-target details **versioned in the
rulebook** rather than compiled in:

```swift
protocol AIDestination {
    var id: String { get }
    func isAvailable() -> Bool           // native app installed?
    func open(prompt: String) async throws
    var acceptsPastedImage: Bool { get }
}
```

Ship adapters for:

| Destination | Native | Web |
|---|---|---|
| Claude | `claude://` URL scheme, or `open -a Claude` | `claude.ai` |
| ChatGPT | native macOS client | `chatgpt.com` |
| Gemini | — | `gemini.google.com` |
| Copilot | — | `copilot.microsoft.com` |
| **Custom** | — | admin-configured URL |

**The custom destination matters commercially.** Many enterprises won't allow claude.ai
directly and route everything through an internal LLM gateway. Without a configurable
destination, those accounts are unsellable.

Prefer the native app when installed — it's faster, it's already authenticated, and it
handles pasted images reliably.

⚠️ **Deep-link parameters change.** Both Claude and ChatGPT have shifted prompt-prefill
formats more than once (`?q=` vs `?prompt=`, differing auto-submit behavior, and the
`claude://` scheme is documented for Claude Desktop but has evolved). **Verify current
formats against vendor documentation at build time** — this spec deliberately does not
assert one.

The adapter layer exists precisely so that a parameter change is a rulebook push rather
than an app release. Note also that URL prefill carries **text only** — images can only
arrive via the pasteboard, which is why step 5 exists at all.

## Failure handling

| Failure | Behavior |
|---|---|
| Screen Recording denied | Text-only handoff, offer the permission in the review, don't nag |
| Destination app not installed | Fall back to web adapter, explicit paste |
| Destination won't open at all | Clipboard plus recovery panel, screenshot included |
| Target never comes frontmost | Leave content on clipboard, tell the user to paste |
| Focus, trust or clipboard changes mid-flight | Stop before the next event, offer manual paste |
| Paste synthesis fails | Same — clipboard is the fallback that always works |
| Capture times out, or the window is ambiguous | Abort silently, no error modal |
| User erases or pauses mid-handoff | Cancel; no delayed step may revive the payload |

The clipboard is the universal fallback: **even in total failure the content is one ⌘V
away**, and the user is never left with a broken interaction and no recourse.
