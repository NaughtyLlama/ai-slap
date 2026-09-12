# AI-slap

Press **⌥Space** on any window. It photographs that window, opens a new chat in the AI
of your choice, and pastes the picture in with whatever you want to ask about it.

There is a hermit crab called Doug living in a dead CRT on your desktop. Drag him
anywhere. Double-click him to hand off. He is not doing anything else, and that is fine.

Nothing is recorded. No database, no log, no analytics, no network code in the app at
all. It knows what is on your screen in the second you press the key, and then it
forgets.

**Sharing it with someone?** Give them [`docs/READ-ME-FIRST.md`](docs/READ-ME-FIRST.md).

## Build it

```bash
./scripts/build-app.sh --install    # build, install to /Applications, launch
./scripts/package.sh                # build a zip to hand to someone else
```

Command Line Tools only. SwiftPM, no Xcode project. Requires macOS 14 or later, because
the screenshot uses `SCScreenshotManager`.

## What it needs from macOS

**Accessibility**, to paste into your AI app. Without it the handoff stops at your
clipboard and you press ⌘V yourself.

**Screen Recording**, to take the screenshot. Without it handoffs go over as text.

Neither is asked for until first run, and both are explained there in terms of what
breaks without them.

## How it got here

It used to be a bigger idea: the app watched which window you were in, classified whether
you were doing something by hand that AI could do, and interrupted you about it. That
layer worked. Over four weeks of real use it fired 31 interruptions and three were
useful, while 59% of the author's screen time was already inside an AI app.

The screenshot was doing all the work the whole time. So the watching, the rules engine,
the on-device personaliser, the local log and everything built to protect that log were
removed, and what is left is the part that was always earning its keep.

[`NOTES.md`](NOTES.md) keeps the reasoning, including the parts that were expensive to
learn. The old detection layer is in the git history if it is ever worth reviving.
