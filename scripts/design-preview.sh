#!/usr/bin/env bash
# Renders Doug and his speech bubble to PNGs, offscreen, from the shipping source.
#
# Both are *drawn* rather than composed from system controls, so "does this still match
# Doug.dc.html" is not a question the code can answer by being read. This is the answer.
# Output is a scratch directory by default and is not committed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${TMPDIR:-/tmp}/aislap-design}"
# swiftc only allows top-level statements in a file called main.swift, so each tool is
# copied into a directory of its own under that name.
mkdir -p "$out/build/sprite" "$out/build/bubble"

cp "$root/scripts/design-preview/sprite.swift" "$out/build/sprite/main.swift"
swiftc -O "$root/Sources/AISlap/DougSprite.swift" \
    "$out/build/sprite/main.swift" \
    -o "$out/build/sprite-preview"
"$out/build/sprite-preview" "$out/doug-moods.png"

cp "$root/scripts/design-preview/bubble.swift" "$out/build/bubble/main.swift"
swiftc -O "$root/Sources/AISlap/DougSprite.swift" \
    "$root/Sources/AISlap/NudgePanel.swift" \
    "$out/build/bubble/main.swift" \
    -o "$out/build/bubble-preview"
"$out/build/bubble-preview" "$out/bubble-with-doug.png" "$out/bubble-alone.png"

echo "==> $out"
ls -1 "$out"/*.png
