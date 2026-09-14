#!/usr/bin/env bash
# Renders Doug and the review dialog to PNGs, offscreen, from the shipping source.
#
# He is *drawn* rather than composed from system controls, so "does this still match
# Doug.dc.html" is not a question the code can answer by being read. This is the answer.
# Output is a scratch directory by default and is not committed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${TMPDIR:-/tmp}/aislap-design}"
# swiftc only allows top-level statements in a file called main.swift, so each tool is
# copied into a directory of its own under that name.
mkdir -p "$out/build/sprite" "$out/build/dialog"

cp "$root/scripts/design-preview/sprite.swift" "$out/build/sprite/main.swift"
swiftc -O "$root/Sources/AISlap/DougSprite.swift" \
    "$out/build/sprite/main.swift" \
    -o "$out/build/sprite-preview"
"$out/build/sprite-preview" "$out/doug-moods.png"

# The review dialog, both shapes, rendered without running a handoff. Alert layout is
# the thing no test can check and no one had looked at before this existed.
cp "$root/scripts/design-preview/dialog.swift" "$out/build/dialog/main.swift"
swiftc -O "$root/Sources/AISlap/DougSprite.swift" \
    "$root/Sources/AISlap/HandoffRecovery.swift" \
    "$root/Sources/AISlap/Handoff.swift" \
    "$root/Sources/AISlap/AIDestination.swift" \
    "$root/Sources/AISlap/Pasteboard.swift" \
    "$root/Sources/AISlap/WindowCapture.swift" \
    "$root/Sources/AISlap/Onboarding.swift" \
    "$root/Sources/AISlap/Destinations.swift" \
    "$out/build/dialog/main.swift" \
    -o "$out/build/dialog-preview"
"$out/build/dialog-preview" "$out"

echo "==> $out"
ls -1 "$out"/*.png
