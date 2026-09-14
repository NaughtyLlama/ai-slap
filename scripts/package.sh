#!/usr/bin/env bash
# Universal Mac release (Intel + Apple Silicon). --notarize submits to Apple using NOTARY_PROFILE.
# --repack archives an existing bundle without rebuilding or changing its signature.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in ""|--notarize|--repack) ;; *) echo "Usage: $0 [--notarize|--repack]" >&2; exit 1 ;; esac
if [[ "$MODE" == "--notarize" ]]; then
    [[ "${DEVELOPER_ID:-}" == "Developer ID Application:"* ]] || {
        echo "Set DEVELOPER_ID to your Developer ID Application signing identity." >&2; exit 1;
    }
    [[ -n "${NOTARY_PROFILE:-}" ]] || {
        echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2; exit 1;
    }
fi

APP="build/AISlap.app"
ZIP="dist/AISlap-universal.zip"
if [[ "$MODE" != "--repack" ]]; then
    # A recipient build must not accidentally use the author's local development key.
    AISLAP_ARCH=universal DEVELOPER_ID="${DEVELOPER_ID:--}" ./scripts/build-app.sh
fi
codesign --verify --deep --strict "$APP"
/usr/bin/lipo "$APP/Contents/MacOS/AISlap" -verify_arch arm64 x86_64 || {
    echo "Universal releases must contain both arm64 and x86_64." >&2; exit 1;
}
mkdir -p dist
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

archive_app() {
    # ditto preserves signatures and stapled tickets. No signing or rebuilding here.
    rm -rf "$STAGING/AISlap"
    mkdir -p "$STAGING/AISlap"
    ditto "$APP" "$STAGING/AISlap/AISlap.app"
    cp docs/READ-ME-FIRST.md "$STAGING/AISlap/READ-ME-FIRST.md"
    cp LICENSE "$STAGING/AISlap/LICENSE"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$STAGING/AISlap" "$ZIP"
}
archive_app
if [[ "$MODE" == "--notarize" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    archive_app
fi
cp docs/READ-ME-FIRST.md dist/READ-ME-FIRST.md
(cd dist && shasum -a 256 AISlap-universal.zip > SHA256SUMS.txt)

if /usr/sbin/spctl --assess --type execute "$APP"; then
    echo "==> Gatekeeper accepts this build."
else
    if [[ "$MODE" == "--notarize" ]]; then
        echo "Notarized release failed Gatekeeper assessment; do not distribute." >&2
        exit 1
    fi
    echo "!! Gatekeeper did not accept this build. Treat it as an unsigned beta."
    echo "!! Read the per-app Open Anyway instructions before sharing."
    echo "!! For notarization, set DEVELOPER_ID and NOTARY_PROFILE, then run:"
    echo "!!   ./scripts/package.sh --notarize"
fi
echo "==> Release: $ZIP (Intel + Apple Silicon, macOS 14+; Intel runtime testing pending)"
