# AI-slap

Press **⌥Space** on any window. It photographs that window, opens a new chat in Claude
(or ChatGPT, or Gemini), and pastes the picture in with whatever you want to ask about it.

There's a hermit crab called Doug on your desktop. Drag him anywhere. Double-click him
to hand off without touching the keyboard. He's not doing anything else.

Nothing is recorded. No database, no log, no analytics, no network. The app only knows
what's on your screen in the second you press the key, and then it forgets.

---

## Installing it

**1. Unzip and drag `AISlap.app` into your Applications folder.**

**2. Open it — the first time needs a detour.**

This app isn't signed with a paid Apple developer certificate, so macOS will refuse it
the first time and say it "cannot be opened because Apple cannot check it for malicious
software." That's a statement about the certificate, not about the app.

- **Right-click** (or Control-click) `AISlap.app` → **Open** → **Open** again.
- On macOS Sequoia and later that button may not appear. Instead go to
  **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next
  to the message about AI-slap. Then open it normally.

If neither works, open Terminal, type `xattr -dr com.apple.quarantine ` (with the
trailing space), drag `AISlap.app` onto the window, and press Return. Then open it.

**3. Say yes to two permissions.**

The app asks for both on first run and explains each one:

- **Accessibility** — lets it paste into your AI app. Without it, the handoff stops at
  your clipboard and you press ⌘V yourself.
- **Screen Recording** — lets it take the screenshot. Without it, handoffs are text only.

macOS may ask you to quit and reopen after granting Accessibility. That's normal, and it
only happens once.

**4. Press ⌥Space on something.**

---

## Using it

| | |
|---|---|
| **⌥Space** | Hand off the window you're looking at |
| **Double-click Doug** | The same thing |
| **Drag Doug** | Move him. He stays where you put him |
| **⌥⌘G** | Hide Doug instantly, for screen shares |

Before anything is sent you get a preview: the screenshot, and a box to type what you
actually want. Change the text, press Return. Nothing is ever submitted for you — you
get the last word in the chat.

If the preview gets annoying, tick **Don't ask again** in it. To bring it back, use
**Ask me before sending** in the menu bar.

## If something's wrong

**The menu-bar icon is a red triangle.** Accessibility got switched off. Click the icon
and then the warning to open the right settings pane.

**⌥Space does nothing.** Another app has claimed that shortcut. The menu says so when
that happens, and the menu item does the same job.

**It hands off to the wrong AI.** Menu bar → **Send it to**.

**The screenshot is missing.** If that app has several windows open and the app can't
tell which one you meant, it won't guess — it sends text instead and tells you. Closing
the extra windows fixes it.

## What it doesn't do

It doesn't watch what you do, keep a history, score your productivity, or phone home.
There's nothing to opt out of, because there's nothing collecting anything.
