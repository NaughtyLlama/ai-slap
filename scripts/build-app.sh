#!/usr/bin/env bash
#
# Builds AISlap.app from the SwiftPM executable. Requires only the Xcode Command
# Line Tools.
#
#   ./scripts/build-app.sh          release build, ad-hoc signed
#   ./scripts/build-app.sh --run    build, then launch it
#
# Signing note: with no Developer ID, the app is signed ad-hoc ("-"). macOS keys the
# Accessibility permission to the code signature, so an ad-hoc build may need the
# permission re-granted after a rebuild. Set DEVELOPER_ID to a real identity once you
# have one and that stops happening:
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AISlap"
BUILD_DIR="build"
APP="${BUILD_DIR}/${APP_NAME}.app"
SIGN_IDENTITY="${DEVELOPER_ID:--}"

echo "==> Building ${APP_NAME} (release)"
swift build -c release

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"

echo "==> Signing with identity: ${SIGN_IDENTITY}"
codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${APP}"
codesign --verify --verbose=1 "${APP}"

echo "==> Built ${APP}"

if [[ "${1:-}" == "--run" ]]; then
    echo "==> Launching"
    pkill -x "${APP_NAME}" 2>/dev/null || true
    open "${APP}"
fi
