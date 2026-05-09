#!/usr/bin/env bash
# Build the Linux x64 static fend host binary plus packaged fendd guest agent
# and stage them into the npm platform package for publishing/testing.
#
# Run from repo root: ./scripts/build-linux-binary.sh

set -euo pipefail

cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
OS="$(uname -s)"
TARGET="x86_64-unknown-linux-musl"

if [ "${OS}" != "Linux" ]; then
    echo "fend: build-linux-binary.sh must run on Linux (got ${OS})" >&2
    exit 1
fi

if [ "${ARCH}" != "x86_64" ]; then
    echo "fend: build-linux-binary.sh currently only stages x86_64 binaries (got ${ARCH})" >&2
    exit 1
fi

if ! rustup target list --installed | grep -qx "${TARGET}"; then
    echo "fend: missing Rust target ${TARGET}" >&2
    echo "  rustup target add ${TARGET}" >&2
    exit 1
fi

cargo build --manifest-path linux/Cargo.toml --release --target "${TARGET}" --bin fend
cargo build --manifest-path fendd/Cargo.toml --release --target "${TARGET}" --bin fendd

PLATFORM_DIR="packages/cli-linux-x64"
mkdir -p "${PLATFORM_DIR}/bin" "${PLATFORM_DIR}/libexec"
cp "linux/target/${TARGET}/release/fend" "${PLATFORM_DIR}/bin/fend"
cp "fendd/target/${TARGET}/release/fendd" "${PLATFORM_DIR}/libexec/fendd"
chmod +x "${PLATFORM_DIR}/bin/fend" "${PLATFORM_DIR}/libexec/fendd"

HOST_SIZE="$(du -h "${PLATFORM_DIR}/bin/fend" | cut -f1)"
GUEST_SIZE="$(du -h "${PLATFORM_DIR}/libexec/fendd" | cut -f1)"
echo ""
echo "fend: Linux binaries staged"
echo "  host   ${PLATFORM_DIR}/bin/fend (${HOST_SIZE})"
echo "  guest  ${PLATFORM_DIR}/libexec/fendd (${GUEST_SIZE})"
echo ""
echo "  Quick check: node bin/fend.js -- node -v"
