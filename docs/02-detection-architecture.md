# 02 — Detection architecture

How the app knows what you're doing, what it deliberately can't see, and why the browser
question drove most of these decisions.

## The tiers

| Tier | Mechanism | Permission | Ships in |
|---|---|---|---|
| 0 | `NSWorkspace.frontmostApplication` → bundle ID | none | v1 |
| 1 | Accessibility API → focused window title | Accessibility (one prompt) | v1 |
| 2 | AppleScript → active tab URL | per-browser Automation | held in reserve |
| 3 | Browser extension → tab origin + page surface | MDM force-install | Phase 3, enterprise only |

**The entire consumer install is tiers 0 and 1: one app, one permission prompt.**

### Tier 0 — frontmost application

`NSWorkspace.shared.frontmostApplication` gives bundle identifier and localized name, with
no permission at all. This alone distinguishes Slack from Chrome from Mail, and it's how
native AI clients are detected — `com.anthropic.claudefordesktop`, ChatGPT's client,
Cursor, and so on.

Collection is **event-driven, not polled**. Subscribe to
`NSWorkspace.didActivateApplicationNotification` and wake only on context change. A 1 Hz
polling loop on a permanently resident app is a battery complaint waiting to happen.

### Tier 1 — window title via Accessibility

```
AXUIElementCreateApplication(pid)
  → kAXFocusedWindowAttribute
    → kAXTitleAttribute
```

Requires the Accessibility permission, prompted once during onboarding via
`AXIsProcessTrustedWithOptions`.

⚠️ **Use the Accessibility API, not `CGWindowListCopyWindowInfo`.** Since macOS 10.15 the
`kCGWindowName` key is withheld unless the app holds **Screen Recording** permission —
a far more alarming prompt for a product already fighting a surveillance perception, and
one that would show up in the menu bar recording indicator. Accessibility alone gets the
title. Screen Recording is deferred until the user's first handoff, where the ask explains
itself.

## The browser problem

Most work happens in a browser. Slack, Gmail, Notion, Linear, and Claude itself are all
just tabs, and to Tier 0 they are indistinguishable — everything is `com.google.Chrome`.

### What titles actually give you

A browser window's title is the page `<title>`, which is more than you'd expect:

| Site | Window title | Readable |
|---|---|---|
| Gmail, inbox | `Inbox (12) - you@co.com - Gmail` | in Gmail, not reading |
| Gmail, one message open | `Re: Q3 budget - you@co.com - Gmail` | **reading one specific message** |
| Slack | `Slack \| #eng-standup \| Acme` | in Slack, which channel |
| Claude | `Claude` | using AI |
| ChatGPT | `ChatGPT` | using AI |
| Google Docs | `Q3 Planning - Google Docs` | in a doc, which doc |

The Gmail row is the important one. The title changes when you open an individual
message, which means **"parked on one email for ninety seconds"** — the single
highest-value trigger in the product — is detectable from the title alone, with no page
access at all.

### Where titles fail

- **Localization.** `Boîte de réception` is not `Inbox`. The rulebook needs locale
  variants for major sites and languages.
- **Ambiguity.** A Notion page titled "Claude" is indistinguishable from claude.ai.
- **No sub-page state.** Whether a Gmail compose overlay is open doesn't change the title.
  Dwell time substitutes.
- **Electron inconsistency.** Some Electron apps expose poor or stale AX titles.
- **Content leakage.** `Re: layoff planning - Gmail` is sensitive. Handling below.

### Why ambiguity is survivable: fail open

The system's two error directions are not symmetric.

- **Missing a manual-work moment** → no interruption. The user notices nothing.
- **Falsely claiming you skipped AI** when you'd just used Claude in a tab → the fastest
  uninstall you can engineer.

So detection is deliberately biased: **when confidence that the user skipped AI is low,
suppress the interruption.** Title ambiguity therefore only ever costs you
*under*-nudging, which is the recoverable direction.

Two supports for the same principle:

- Every interruption carries an **"I already did"** button that dismisses *and* counts as
  a win. This is also the only coverage for AI used on a phone or another machine, which
  is otherwise completely invisible.
- Any window title matching a known AI surface sets a **10-minute grace period** during
  which no interruption fires for any rule.

### The fallbacks, and why they're not in v1

**Tier 2 — AppleScript URL read.**
`tell application "Google Chrome" to get URL of active tab of front window` returns the
exact URL, and the same dictionary works across Chromium browsers (Chrome, Edge, Brave,
Arc, Vivaldi). Safari has its own equivalent. Firefox has none.

Cost is one extra Automation prompt at onboarding — *not* a second install — but it's
per-browser, the dialog wording is alarming ("wants access to control Google Chrome"), and
Apple has steadily tightened Apple Events. **Ship only if Phase 0 shows titles are
insufficient.**

**Tier 3 — browser extension.** A Chromium extension plus a bundled Safari App Extension
would report the tab origin over Chrome
[native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)
and could read page surfaces directly — is a compose box open, how long is the draft.
Accurate, and it also unlocks in-page interruptions.

**It is not in the consumer path, deliberately.** Asking a regular user to install a
desktop app *and* a browser extension is two installs and two permission flows, and every
step in that funnel costs activation this product can't spare. It survives only as an
enterprise deployment where IT force-installs it via `ExtensionInstallForcelist` +
`NativeMessagingAllowlist` in an MDM profile — the employee installs nothing, sees no
prompt, and accuracy improves invisibly. See [08](08-roadmap-and-risks.md), Phase 3.

## Signals collected

Per context change, held in memory:

| Signal | Source | Leaves device |
|---|---|---|
| Bundle ID | NSWorkspace | never |
| Window title | AX API | **never** — see below |
| Dwell time in current context | computed | never |
| Time since last AI context | computed | never |
| Rule ID + outcome | rules engine | yes, as an anonymous counter |

**Title handling.** A title is matched against rulebook patterns and immediately reduced
to a category token — `gmail.message.open`, `slack.channel`, `ai.claude`. The raw string
is discarded within the tick. It is never written to disk, never logged, never
transmitted. This is what makes it defensible to read window titles at all.

## Deliberately not collected

- **No global keystroke tap.** A `CGEventTap` would enable "you've been typing this by
  hand for three minutes," and it is not worth it. A monitoring product with a global key
  hook is a trust catastrophe and a security-review dead end, regardless of how carefully
  it only counts keystrokes. Dwell time gets most of the value at none of the cost.
  Revisit only if Phase 0 says dwell is inadequate — and even then, weigh it hard.
- **No screen capture for detection.** Screenshots happen only in the handoff flow, on
  explicit user action. See [05](05-handoff.md).
- **No URL paths or query strings**, even in the enterprise extension tier. Origin only.
- **No clipboard monitoring, no audio, no camera, no network inspection.**

## The install/permission budget

Treat this as a hard constraint, not an afterthought. Every additional install step or TCC
dialog measurably reduces activation, and this product needs mass consumer adoption to
reach the teams that pay.

**v1 spends the entire budget on one thing: one app, one Accessibility prompt.**

Screen Recording is requested lazily on first handoff. Anything costing a second install
must earn its place with Phase 0 data.

## Known-hard cases, stated honestly

- **AI inside an IDE.** Cursor and Copilot usage is invisible from outside the editor. A
  developer using Copilot all day looks identical to one who isn't. Mitigation: treat
  known AI-native editors as AI contexts wholesale, and accept the imprecision.
- **AI on another device.** Phone, tablet, personal laptop — entirely invisible. The
  "I already did" button is the only coverage.
- **Virtual machines and remote desktops.** Everything inside a Parallels or Citrix window
  reads as one opaque app.
- **Multiple monitors and Spaces.** Only the frontmost window on the active Space is
  observed, which is correct — but a long-running task on a second monitor is invisible.
