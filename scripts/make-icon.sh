#!/usr/bin/env bash
# Builds Resources/AISlap.icns from the shipping sprite, so the icon can never drift
# from the character. Run it when Doug changes; the result is committed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
mkdir -p "$work/AISlap.iconset"
swiftc -O "$root/Sources/AISlap/DougSprite.swift" "$root/scripts/make-icon/main.swift" \
    -o "$work/make-icon"
"$work/make-icon" "$work/AISlap.iconset"
iconutil -c icns "$work/AISlap.iconset" -o "$root/Resources/AISlap.icns"
echo "==> $root/Resources/AISlap.icns"
