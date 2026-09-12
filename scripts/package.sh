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
# Ask the question that actually matters — "will another Mac open this?" — rather than
# parsing the signature and inferring. Gatekeeper is the thing recipients will meet.
if /usr/sbin/spctl --assess --type execute build/AISlap.app >/dev/null 2>&1; then
    echo "==> Gatekeeper accepts this build. Recipients can just double-click."
else
    echo "!!  Gatekeeper REJECTS this build, which is expected without a Developer ID."
    echo "!!  Recipients get \"Apple cannot check it for malicious software\" and need the"
    echo "!!  right-click -> Open step in dist/READ-ME-FIRST.md."
    echo "!!"
    echo "!!  To remove that step:"
    echo "!!    DEVELOPER_ID=\"Developer ID Application: NAME (TEAMID)\" ./scripts/package.sh"
    echo "!!    xcrun notarytool submit dist/AISlap.zip --keychain-profile PROFILE --wait"
    echo "!!    xcrun stapler staple build/AISlap.app && ./scripts/package.sh"
fi
echo "==> $(cd dist && pwd)"
ls -lh dist
