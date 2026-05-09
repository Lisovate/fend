#!/usr/bin/env bash
# Publish one platform package first, then the root wrapper package.
# Use --dry-run for local release verification before the real npm publish.
#
# Examples:
#   ./scripts/publish-npm.sh --platform linux-x64 --dry-run
#   ./scripts/publish-npm.sh --platform linux-x64 --tag alpha

set -euo pipefail

cd "$(dirname "$0")/.."

PLATFORM=""
TAG="latest"
DRY_RUN=0
NPM_CACHE_DIR="${NPM_CONFIG_CACHE:-/tmp/fend-npm-cache}"

mkdir -p "${NPM_CACHE_DIR}"
export NPM_CONFIG_CACHE="${NPM_CACHE_DIR}"

usage() {
    cat <<'EOF'
usage: ./scripts/publish-npm.sh [options]

options:
  --platform name       Target npm platform package. Required.
                        Supported: linux-x64, darwin-arm64.
  --tag name            npm dist-tag to publish under. Default: latest.
  --dry-run             Run npm publish --dry-run for both packages.
  -h, --help            Show this help.

Publishes the platform package first, then @fendsh/cli.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --platform)
            PLATFORM="${2:-}"
            shift 2
            ;;
        --tag)
            TAG="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
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
    echo "fend: --platform is required" >&2
    usage >&2
    exit 1
fi

case "${PLATFORM}" in
    linux-x64|darwin-arm64)
        ;;
    *)
        echo "fend: unsupported npm platform package: ${PLATFORM}" >&2
        exit 1
        ;;
esac

./scripts/pack-npm.sh --platform "${PLATFORM}" >/dev/null

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "fend: dry-run pack check for @fendsh/cli-${PLATFORM}"
    npm pack --dry-run "./packages/cli-${PLATFORM}"
    echo ""
    echo "fend: dry-run pack check for @fendsh/cli"
    npm pack --dry-run "."
    exit 0
fi

PUBLISH_ARGS=(--access public --tag "${TAG}")

echo "fend: publishing @fendsh/cli-${PLATFORM}"
(cd "packages/cli-${PLATFORM}" && npm publish "${PUBLISH_ARGS[@]}")

echo ""
echo "fend: publishing @fendsh/cli"
(cd . && npm publish "${PUBLISH_ARGS[@]}")
