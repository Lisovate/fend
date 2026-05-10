#!/bin/bash
# Build the macOS arm64 fend binary, sign with Developer ID, notarize,
# and stage it into the platform package for npm publishing.
#
# Default flow assumes:
#   - Developer ID Application identity in the login Keychain
#     (Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID)
#   - Notarytool keychain profile named "fend-notarytool"
#     (xcrun notarytool store-credentials "fend-notarytool" ...)
#
# Env overrides:
#   FEND_TEAM_ID              Apple Team ID (default: 487XSFNFDS)
#   FEND_SIGN_IDENTITY        codesign --sign argument (default: auto-detected
#                             from Keychain for FEND_TEAM_ID)
#   FEND_NOTARYTOOL_PROFILE   notarytool --keychain-profile (default: fend-notarytool)
#   FEND_AD_HOC=1             Ad-hoc sign only (local dev; no Developer ID needed,
#                             will not run on other Macs)
#   FEND_SKIP_NOTARIZE=1      Sign with Developer ID but skip Apple notarization
#                             (fast iteration; will not pass Gatekeeper on end users)
#
# Run from repo root:  ./scripts/build-binary.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "fend: build-binary.sh must run on Apple Silicon (got $ARCH)" >&2
    exit 1
fi

# Build release
swift build -c release --package-path swift

PLATFORM_DIR="packages/cli-darwin-arm64/bin"
mkdir -p "$PLATFORM_DIR"
cp swift/.build/release/fend "$PLATFORM_DIR/fend"
chmod +x "$PLATFORM_DIR/fend"
BINARY="$PLATFORM_DIR/fend"
ENTITLEMENTS="swift/fend.entitlements"

# ── Ad-hoc shortcut for local dev ───────────────────────────────────
if [ "${FEND_AD_HOC:-0}" = "1" ]; then
    echo "fend: ad-hoc signing (local dev — will not run on other Macs)"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
    SIZE=$(du -h "$BINARY" | cut -f1)
    echo "fend: ad-hoc-signed binary → $BINARY ($SIZE)"
    exit 0
fi

# ── Resolve Developer ID identity ────────────────────────────────────
TEAM_ID="${FEND_TEAM_ID:-487XSFNFDS}"
SIGN_IDENTITY="${FEND_SIGN_IDENTITY:-}"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -p codesigning -v \
        | grep "Developer ID Application:" \
        | grep "($TEAM_ID)" \
        | head -1 \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')
fi

if [ -z "$SIGN_IDENTITY" ]; then
    echo "fend: no Developer ID Application identity for team $TEAM_ID in Keychain." >&2
    echo "  Available identities:" >&2
    security find-identity -p codesigning -v >&2 || true
    echo "" >&2
    echo "  Add one via Xcode → Settings → Accounts → Manage Certificates," >&2
    echo "  or set FEND_AD_HOC=1 for ad-hoc signing." >&2
    exit 1
fi

# ── Sign ─────────────────────────────────────────────────────────────
echo "fend: signing with: $SIGN_IDENTITY"
codesign --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    --timestamp \
    "$BINARY"

codesign --verify --strict "$BINARY"

if [ "${FEND_SKIP_NOTARIZE:-0}" = "1" ]; then
    SIZE=$(du -h "$BINARY" | cut -f1)
    echo ""
    echo "fend: Developer ID signed (notarization skipped) → $BINARY ($SIZE)"
    echo "  Will not pass Gatekeeper on end-user Macs until notarized."
    exit 0
fi

# ── Notarize ─────────────────────────────────────────────────────────
# Bare CLI binaries can't be stapled. Apple's notary database records the
# signed binary's hash; Gatekeeper checks online on first launch.
NOTARYTOOL_PROFILE="${FEND_NOTARYTOOL_PROFILE:-fend-notarytool}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
ZIP_PATH="$TMPDIR/fend.zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"

echo "fend: submitting to Apple notary (typically 1-5 min)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

SIZE=$(du -h "$BINARY" | cut -f1)
echo ""
echo "fend: signed + notarized binary → $BINARY ($SIZE)"
echo ""
echo "  Codesign:     codesign -dv $BINARY"
echo "  Quick check:  node bin/fend.js --version"
