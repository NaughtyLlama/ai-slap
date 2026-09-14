# AI-slap: start here

Press **⌥Space** to capture the window you're using, review the picture, and hand it to
an AI. Doug, the hermit crab on your desktop, does the same thing when double-clicked.
AI-slap never submits the chat for you.

**It also watches which window you're in.** If you've been stuck on the same email or
document for a while and haven't touched AI recently, Doug suggests handing it over. A
few times a day at most, never while your microphone is in use, never at night. Switch it off under
**Watch and nudge me** in the menu, or silence it for a few hours with **Quiet for a
while**.

That watching reads the name of your frontmost window, enough to tell an email from a
spreadsheet. It stays in memory, is never written to disk, and is gone when you quit.
No history, no learning, nothing leaves your Mac.

## Before downloading

- **Intel or Apple Silicon Mac, macOS 14+.** Check Apple menu → About This Mac.
  The universal download includes both architectures. **Intel build included; runtime
  testing pending.** Windows and Linux are unsupported.
- Sign in to your preferred AI app or website first. Its account requirements and charges
  apply. AI-slap itself needs no API key or account.
- Native AI apps can receive automatic paste when their composer is detected. **Browser
  destinations require manual paste**, described below.

## Install

1. Open [the latest release](https://github.com/NaughtyLlama/ai-slap/releases/latest).
   Download **AISlap-universal.zip** from Assets, not “Source code.” Versions before
   v0.2.2 were Apple Silicon only; Intel users need v0.2.2 or later.
2. Unzip, open the AI-slap folder, and drag **AISlap.app** into **Applications**.
3. Open AISlap.app. A signed and notarized release opens through the normal macOS dialog.
   **The current beta is ad-hoc signed and is not notarized by Apple.** macOS may block it.
   If you trust this download and choose to proceed, first attempt to open it, then go
   to **System Settings → Privacy & Security → Open Anyway** beside the AI-slap message.
   Confirm the per-app exception. If that option is unavailable, stop and ask for help;
   a managed work Mac may not allow it. Do not disable Gatekeeper or remove quarantine
   in Terminal. See [Apple's instructions](https://support.apple.com/en-au/guide/mac-help/-mh40616/mac).
4. Choose your AI in the welcome dialog. Setup offers **Accessibility** (automatic paste)
   and **Screen Recording** (screenshots). Enable each in System Settings. Return to
   AI-slap to continue; if macOS asks you to quit and reopen, setup resumes after relaunch.
   You can reopen it at any time through **menu bar → Set up AI-slap…**.
5. Open a harmless window, such as a test note. Press **⌥Space**, check the screenshot,
   and type your question. Press **Send** to hand it to the AI. Review the resulting
   draft there before submitting it yourself.

You can skip permissions. Without Screen Recording, only your typed prompt is available.
Without Accessibility, use the manual paste flow. Neither permission is permission for
AI-slap to submit a chat.

## In a browser, or when automatic paste stops

AI-slap opens your selected destination and shows **Finish your handoff**.

1. Sign in if necessary and start a new chat yourself.
2. Click the chat composer and press **⌘V** to paste the prompt. If the panel says your
   newer clipboard was kept, click **Copy prompt** first.
3. Click **Copy screenshot**, return to the composer, and press **⌘V** again. The button
   is unavailable if no screenshot was captured.
4. Check that both arrived, then click **Done** on the recovery panel. Submit the chat
   yourself only when ready.

The recovery panel expires after five minutes. If sign-in takes longer, run a new handoff.

## Controls and troubleshooting

| Control | Action |
|---|---|
| ⌥Space | Capture and review the current window |
| Double-click Doug | Start the same handoff |
| Drag Doug | Move him |
| ⌥⌘G | Hide or show Doug, including before a screen share |
| Menu bar → Send it to | Change AI destination |
| Menu bar → Set up AI-slap… | Revisit destination and permission setup |
| Menu bar → Ask me before sending | Restore the preview after “Don't ask again” |
| Menu bar → Quit AI-slap | Quit the app |

**Missing screenshot:** check Screen Recording first. If multiple windows cannot be
uniquely identified, AI-slap sends text only; try a single window. Reopen after permission
changes if macOS requests it.

**⌥Space does nothing:** another app may own the shortcut. Try double-clicking Doug or
menu bar → Hand off this window.

**Automatic paste doesn't work:** use the recovery panel. App versions and composer
layouts can differ; automatic paste is attempted, not guaranteed.

**Trying it on Intel:** this build compiles for Intel but has not been tested on an Intel
Mac. Start with a harmless test note and verify permissions, the screenshot preview, and
pasting into your AI. If a step fails, report your Mac model, macOS version, AI app or
browser version, and which step failed. Do not include private screenshots.

**After a locally rebuilt app loses Accessibility:** remove its old entry in System
Settings → Privacy & Security → Accessibility, add the rebuilt app, and re-enable it.

## Privacy

AI-slap captures one window when you ask. It has no screenshot history, analytics,
database, or network client. It stores preferences and emits diagnostic status messages.
Screenshots stay in memory during the handoff; failed handoffs remain recoverable for up
to five minutes or until the panel is closed or replaced.

The handoff uses the **system clipboard**. Automatic paste restores the previous clipboard
only while AI-slap still owns it. Manual copies can remain until you copy something else,
and clipboard managers or clipboard syncing can retain them.

**Pasting shares content with the chosen AI app or website.** That service controls its
uploads, retention and privacy settings, including behavior before you submit a chat.
Review screenshots for private information before approving them. “Never auto-submit”
does not mean the receiving service cannot process a pasted image.

## Remove it

Turn off **Open at login** in AI-slap's menu if enabled, choose **Quit AI-slap**, then move
AISlap.app from Applications to Trash. Remove its Accessibility and Screen Recording
entries in System Settings if desired. Preferences may remain on the Mac.
