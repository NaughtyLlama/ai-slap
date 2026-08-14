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

### 3. Build the prompt

From the matched rule's `promptTemplate` ([03](03-rules-and-nudges.md)), or a generic
"Here's what I'm working on — can you help me with this?" for a context-free hotkey press.

Templates are plain text with no interpolated content from the screen. The window title is
*not* injected — it's already been reduced to a category token and discarded, and injecting
it would leak exactly the content [02](02-detection-architecture.md) is careful not to keep.

### 4. Stage the pasteboard

Image + prompt text onto `NSPasteboard.general`.

⚠️ **Save and restore the user's existing clipboard.** Silently destroying someone's
clipboard is a small betrayal that people notice and resent. Snapshot before, restore
~2 seconds after the paste.

### 5. Open the destination and paste

Open the target, wait for it to become frontmost (poll `frontmostApplication`, ~2s timeout),
then synthesize ⌘V via `CGEvent` — which works because Accessibility is already granted.

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
| Screen Recording denied | Text-only handoff, explain once, don't re-prompt |
| Destination app not installed | Fall back to web adapter |
| Target never comes frontmost | Leave content on clipboard, tell the user to paste |
| Paste synthesis fails | Same — clipboard is the fallback that always works |
| Capture times out | Abort silently, no error modal |

The clipboard is the universal fallback: **even in total failure the content is one ⌘V
away**, and the user is never left with a broken interaction and no recourse.
