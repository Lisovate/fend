#!/usr/bin/env bash
# Pack the unpublished Linux npm artifacts, install them into a throwaway npm
# prefix, and verify the installed wrapper resolves the packaged Linux binary.
#
# Run from repo root: ./scripts/test-linux-npm-package.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "fend: test-linux-npm-package.sh requires a Linux x86_64 host" >&2
    exit 1
fi

if ! command -v node >/dev/null 2>&1; then
    echo "fend: node is required for npm package verification" >&2
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "fend: npm is required for npm package verification" >&2
    exit 1
fi

NPM_CACHE_DIR="${NPM_CONFIG_CACHE:-/tmp/fend-npm-cache}"
mkdir -p "${NPM_CACHE_DIR}"
export NPM_CONFIG_CACHE="${NPM_CACHE_DIR}"

PACK_DIR="$(mktemp -d /tmp/fend-npm-pack.linux-x64.XXXXXX)"
INSTALL_PREFIX="$(mktemp -d /tmp/fend-npm-prefix.XXXXXX)"
FEND_HOME_DIR="$(mktemp -d /tmp/fend-npm-home.XXXXXX)"
CID=$(( 20000 + ($$ % 30000) ))
VERSION="$(node -p "require('./package.json').version")"

./scripts/pack-npm.sh --platform linux-x64 --output-dir "${PACK_DIR}" >/dev/null

PLATFORM_TARBALL="${PACK_DIR}/fendsh-cli-linux-x64-${VERSION}.tgz"
ROOT_TARBALL="${PACK_DIR}/fendsh-cli-${VERSION}.tgz"

if [ ! -f "${PLATFORM_TARBALL}" ] || [ ! -f "${ROOT_TARBALL}" ]; then
    echo "fend: expected npm tarballs were not created in ${PACK_DIR}" >&2
    exit 1
fi

npm install -g --prefix "${INSTALL_PREFIX}" --omit=optional \
    "${PLATFORM_TARBALL}" "${ROOT_TARBALL}" >/dev/null

FEND_BIN="${INSTALL_PREFIX}/bin/fend"
if [ ! -x "${FEND_BIN}" ]; then
    echo "fend: installed fend wrapper was not found at ${FEND_BIN}" >&2
    exit 1
fi

echo "fend: installed wrapper"
echo "  prefix   ${INSTALL_PREFIX}"
echo "  binary   ${FEND_BIN}"
echo ""

echo "fend: doctor"
"${FEND_BIN}" doctor

echo ""
echo "fend: node -v"
FEND_HOME="${FEND_HOME_DIR}" FEND_QEMU_CID="${CID}" "${FEND_BIN}" node -v
