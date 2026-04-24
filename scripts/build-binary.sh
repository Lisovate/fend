#!/bin/bash
# Build the macOS arm64 fend binary and stage it into the platform package
# for npm publishing.
#
# WARNING: this only ad-hoc codesigns. For actual distribution via npm the
# binary MUST be Developer ID signed AND notarized — Apple Virtualization
# entitlements are otherwise rejected at runtime on end-user machines.
#
# Run from repo root:  ./scripts/build-binary.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
if [ "$ARCH" != "arm64" ]; then
    echo "fend: build-binary.sh must run on Apple Silicon (got $ARCH)" >&2
    exit 1
fi

# Build release + entitlements
make -C swift sign

PLATFORM_DIR="packages/cli-darwin-arm64/bin"
mkdir -p "$PLATFORM_DIR"
cp swift/.build/release/fend "$PLATFORM_DIR/fend"
chmod +x "$PLATFORM_DIR/fend"

SIZE=$(du -h "$PLATFORM_DIR/fend" | cut -f1)
echo ""
echo "fend: native binary staged → $PLATFORM_DIR/fend ($SIZE)"
echo ""
echo "  Quick check:  node bin/fend.js --version"
echo ""
echo "  Before npm publish: replace ad-hoc sign with Developer ID + notarize."
