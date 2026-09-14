# AI-slap

Press **⌥Space** to take a picture of the window you're using, review it, and hand it to
your AI with a question. Native apps can receive automatic paste; in a browser you paste
the prompt and screenshot yourself. **AI-slap never submits the chat.**

Doug is a hermit crab living in a dead CRT on your desktop. Drag him anywhere.
Double-click him to start a handoff. **⌥⌘G** hides him before a screen share.

## Download and run

**It watches which window you're in, lightly.** Stuck on the same document for a while
with no recent AI use, and Doug suggests handing it over. Fixed rules, a few times a day
at most, nothing during calls or at night. Window names stay in memory, are never written
to disk, and go when you quit — there is no history and nothing that learns.

**[Download the latest release](https://github.com/NaughtyLlama/ai-slap/releases/latest)**
→ Assets → **AISlap-universal.zip**.

**Intel or Apple Silicon Mac, macOS 14+.** One universal download contains both
architectures. **Intel build included; runtime testing pending.** Windows and Linux
are unsupported. Sign in to your preferred AI app or website first; AI-slap needs no API key.

Unzip, drag AISlap.app to Applications, open it, and follow setup for Accessibility and
Screen Recording. The current beta is **not notarized**, so macOS may require a per-app
Open Anyway exception. Follow the full **[installation and privacy guide](docs/READ-ME-FIRST.md)**,
including browser paste instructions. The guide is included in the zip.

## Build from source

Install Apple's Command Line Tools first:

```bash
xcode-select --install
```

Wait for that installation to finish, then:

```bash
git clone https://github.com/NaughtyLlama/ai-slap.git
cd ai-slap
./scripts/build-app.sh
```

Drag `build/AISlap.app` to Applications and open it. Follow the same setup guide.
`./scripts/build-app.sh --install` builds, replaces an existing copy in /Applications,
and launches it. `--run` launches from build/ instead. A locally rebuilt ad-hoc app may
need Accessibility re-granted; use `scripts/make-signing-identity.sh` for an optional
stable local development identity.

The default source build uses your Mac's architecture. For a universal app, run
`AISLAP_ARCH=universal ./scripts/build-app.sh`. This builds each architecture separately
and combines them with `lipo`, so full Xcode is not required. Intel runtime behavior
still needs testing on an Intel Mac.

```bash
swift test
./scripts/package.sh       # Universal Mac beta in dist/, ad-hoc unless DEVELOPER_ID is set
```

## Package a notarized release

With a Developer ID Application certificate and a notarytool keychain profile configured:

```bash
export DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-notarytool-profile"
./scripts/package.sh --notarize
```

This builds, signs, submits to Apple, staples, then archives the same app and checks
Gatekeeper. `--repack` only archives an existing build, preserving its signature and
stapled ticket. `dist/SHA256SUMS.txt` accompanies the zip. Update the version in
Resources/Info.plist and the release notes before publishing. Test the actual downloaded
zip on a fresh supported Mac/account, including both permissions and a real handoff.

## Privacy

AI-slap has no screenshot history, database, analytics or network client. It stores
preferences, emits diagnostic messages, and temporarily holds handoff content in memory.
It uses the system clipboard, which other software may retain. **Once pasted, content
is controlled by your chosen AI app/site and its privacy settings.** Review private
information before approving a handoff. See the [full privacy explanation](docs/READ-ME-FIRST.md#privacy).

## How it got here

The app originally watched windows and interrupted the author when AI might help.
Four weeks of use produced 31 interruptions and only three useful ones. The screenshot
was doing the work, so the detection layer and local activity log were removed.
[NOTES.md](NOTES.md) keeps the engineering history. Older detection code remains in Git.

## License

[MIT](LICENSE), copyright Chen Lehner.
