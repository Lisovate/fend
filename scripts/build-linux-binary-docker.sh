#!/usr/bin/env bash
# Build the Linux x64 fend host binary + fendd guest agent inside a Docker
# container. Lets you stage the npm platform package on any host (including
# macOS, where scripts/build-linux-binary.sh refuses to run natively).
#
# Uses Docker named volumes for cargo's target/ dirs to keep host-side
# target/ state untouched and to cache between runs.
#
# Run from repo root: ./scripts/build-linux-binary-docker.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v docker >/dev/null 2>&1; then
    echo "fend: docker is required (Docker Desktop or compatible runtime)" >&2
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "fend: docker daemon is not running" >&2
    exit 1
fi

RUST_IMAGE="rust:1-slim-bookworm"

echo "fend: building Linux x64 binaries inside Docker"
echo "  image: ${RUST_IMAGE}"
if [ "$(uname -m)" = "arm64" ]; then
    echo "  note: linux/amd64 emulation on Apple Silicon is slower than native"
fi
echo ""

docker run --rm \
    --platform=linux/amd64 \
    -v "$PWD":/work \
    -v fend-docker-linux-target:/work/linux/target \
    -v fend-docker-fendd-target:/work/fendd/target \
    -w /work \
    "${RUST_IMAGE}" \
    bash -c '
        set -euo pipefail
        apt-get update -qq && \
            apt-get install -y -qq --no-install-recommends musl-tools >/dev/null
        rustup target add x86_64-unknown-linux-musl
        ./scripts/build-linux-binary.sh
    '

echo ""
echo "fend: Linux binaries staged → packages/cli-linux-x64/"
echo "  bin/fend       $(du -h packages/cli-linux-x64/bin/fend | cut -f1)"
echo "  libexec/fendd  $(du -h packages/cli-linux-x64/libexec/fendd | cut -f1)"
echo ""
echo "  Verify the binaries are statically linked Linux ELFs:"
echo "    file packages/cli-linux-x64/bin/fend"
echo "    file packages/cli-linux-x64/libexec/fendd"
echo ""
echo "  Then dry-run the npm publish:"
echo "    ./scripts/publish-npm.sh --platform linux-x64 --dry-run"
