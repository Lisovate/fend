#!/usr/bin/env bash
# Stage the native binary for one platform package, then create npm tarballs
# for the platform package and the root wrapper package.
#
# Examples:
#   ./scripts/pack-npm.sh
#   ./scripts/pack-npm.sh --platform linux-x64 --output-dir /tmp/fend-npm-pack

set -euo pipefail

cd "$(dirname "$0")/.."

PLATFORM=""
OUTPUT_DIR=""
NPM_CACHE_DIR="${NPM_CONFIG_CACHE:-/tmp/fend-npm-cache}"

mkdir -p "${NPM_CACHE_DIR}"
export NPM_CONFIG_CACHE="${NPM_CACHE_DIR}"

usage() {
    cat <<'EOF'
usage: ./scripts/pack-npm.sh [options]

options:
  --platform name       Target npm platform package. Default: detect from host.
                        Supported: linux-x64, darwin-arm64.
  --output-dir path     Directory for generated .tgz files.
                        Default: /tmp/fend-npm-pack.<platform>.<pid>
  -h, --help            Show this help.
EOF
}

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    case "${os}:${arch}" in
        Linux:x86_64) echo "linux-x64" ;;
        Darwin:arm64) echo "darwin-arm64" ;;
        *)
            echo "fend: unsupported host for automatic platform detection: ${os} ${arch}" >&2
            echo "  pass --platform linux-x64 or --platform darwin-arm64 explicitly" >&2
            exit 1
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            PLATFORM="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "fend: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "${PLATFORM}" ]; then
    PLATFORM="$(detect_platform)"
fi

case "${PLATFORM}" in
    linux-x64)
        ./scripts/build-linux-binary.sh
        ;;
    darwin-arm64)
        ./scripts/build-binary.sh
        ;;
    *)
        echo "fend: unsupported npm platform package: ${PLATFORM}" >&2
        exit 1
        ;;
esac

if [ -z "${OUTPUT_DIR}" ]; then
    OUTPUT_DIR="/tmp/fend-npm-pack.${PLATFORM}.$$"
fi
mkdir -p "${OUTPUT_DIR}"

ROOT_VERSION="$(node -p "require('./package.json').version")"
PLATFORM_PKG="@fendsh/cli-${PLATFORM}"
PLATFORM_VERSION="$(node -p "require('./packages/cli-${PLATFORM}/package.json').version")"
ROOT_OPTIONAL_VERSION="$(node -p "((require('./package.json').optionalDependencies || {})['${PLATFORM_PKG}']) || ''")"

if [ "${ROOT_VERSION}" != "${PLATFORM_VERSION}" ]; then
    echo "fend: version mismatch between root (${ROOT_VERSION}) and ${PLATFORM_PKG} (${PLATFORM_VERSION})" >&2
    exit 1
fi

if [ "${ROOT_VERSION}" != "${ROOT_OPTIONAL_VERSION}" ]; then
    echo "fend: root optionalDependencies entry for ${PLATFORM_PKG} is ${ROOT_OPTIONAL_VERSION}, expected ${ROOT_VERSION}" >&2
    exit 1
fi

ROOT_TARBALL="fendsh-cli-${ROOT_VERSION}.tgz"
PLATFORM_TARBALL="fendsh-cli-${PLATFORM}-${PLATFORM_VERSION}.tgz"

rm -f "${OUTPUT_DIR}/${ROOT_TARBALL}" "${OUTPUT_DIR}/${PLATFORM_TARBALL}"

npm pack --silent --pack-destination "${OUTPUT_DIR}" "./packages/cli-${PLATFORM}" >/dev/null
npm pack --silent --pack-destination "${OUTPUT_DIR}" "." >/dev/null

echo ""
echo "fend: npm tarballs ready"
echo "  platform ${OUTPUT_DIR}/${PLATFORM_TARBALL}"
echo "  root     ${OUTPUT_DIR}/${ROOT_TARBALL}"
echo ""
echo "  Local install check:"
echo "    ./scripts/test-linux-npm-package.sh"
