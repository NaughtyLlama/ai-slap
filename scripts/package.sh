#!/usr/bin/env bash
# Builds a zip you can hand to someone else, plus the note they need to get past
# Gatekeeper. Everything lands in dist/.
#
# Without a paid Apple Developer ID the result is ad-hoc signed, which means the first
# launch on any other Mac needs a right-click → Open. Set DEVELOPER_ID and notarise to
# remove that step:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/package.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build dist
./scripts/build-app.sh

mkdir -p dist
/usr/bin/ditto -c -k --keepParent build/AISlap.app dist/AISlap.zip
cp docs/READ-ME-FIRST.md dist/READ-ME-FIRST.md

echo
if codesign -dv build/AISlap.app 2>&1 | grep -q "TeamIdentifier=not set"; then
    echo "!!  Ad-hoc signed. Recipients will hit Gatekeeper and need the right-click → Open"
    echo "!!  step in dist/READ-ME-FIRST.md. A Developer ID plus notarisation removes it."
else
    echo "==> Signed with a real identity. Notarise before sending:"
    echo "    xcrun notarytool submit dist/AISlap.zip --keychain-profile <profile> --wait"
    echo "    xcrun stapler staple build/AISlap.app   # then re-zip"
fi
echo "==> $(cd dist && pwd)"
ls -lh dist
