#!/usr/bin/env bash
# Build the macOS arm64 guest runtime as a single distributable bundle.
#
# Produces:
#   <output-dir>/fend-runtime-darwin-arm64-v<VERSION>.tar.zst
#   <output-dir>/fend-runtime-darwin-arm64-v<VERSION>.tar.zst.sha256
#   <output-dir>/manifest.json   (per-file SHAs, fendd version, kernel source)
#
# Bundle contents (untarred):
#   vmlinuz, initrd, rootfs.img, manifest.json
#
# Designed for CI on a Linux arm64 runner (ubuntu-24.04-arm).
# Reuses the same shapes prepare-runtime.sh produces, but parameterised so the
# guest-side build is one source of truth.
#
# Requirements on the runner:
#   - curl, cpio, gzip, tar, zstd, sha256sum, file, jq
#   - docker (used for the rootfs.img mke2fs step)
#   - the fendd binary at $FENDD_BIN, prebuilt for aarch64-unknown-linux-musl
#
# Usage:
#   ./scripts/build-runtime-bundle.sh \
#       --version 0.1.0-alpha.3 \
#       --fendd-bin fendd/target/aarch64-unknown-linux-musl/release/fendd \
#       --output-dir /tmp/fend-runtime-out

set -euo pipefail

# ─── arg parsing ─────────────────────────────────────────────────────

VERSION=""
FENDD_BIN=""
OUTPUT_DIR=""
SKIP_CLAUDE="${FEND_SKIP_CLAUDE:-0}"

usage() {
    cat <<'EOF'
usage: ./scripts/build-runtime-bundle.sh [options]

options:
  --version VERSION         Fend version this bundle is for (no leading v).
  --fendd-bin PATH          aarch64-musl fendd binary to embed in the rootfs.
  --output-dir PATH         Where to write bundle + manifest + sha256 sidecar.
  --skip-claude             Skip downloading the optional Claude guest tool.
  -h, --help                Show this help.

The script also honours these env vars as fallbacks:
  FENDD_BIN, FEND_SKIP_CLAUDE.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --fendd-bin) FENDD_BIN="${2:-}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        --skip-claude) SKIP_CLAUDE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "fend: unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "fend: --version is required" >&2
    exit 1
fi

if [ -z "$FENDD_BIN" ]; then
    FENDD_BIN="${FENDD_BIN_ENV:-fendd/target/aarch64-unknown-linux-musl/release/fendd}"
fi

if [ ! -x "$FENDD_BIN" ]; then
    echo "fend: fendd binary not found or not executable at $FENDD_BIN" >&2
    echo "      build it first: cd fendd && cargo build --release --target aarch64-unknown-linux-musl --bin fendd" >&2
    exit 1
fi

FENDD_TYPE=$(file "$FENDD_BIN" 2>/dev/null || echo "")
if ! echo "$FENDD_TYPE" | grep -q "ELF 64-bit.*aarch64"; then
    echo "fend: fendd is not an aarch64 ELF binary" >&2
    echo "  got: $FENDD_TYPE" >&2
    exit 1
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$(mktemp -d -t fend-runtime-bundle-XXXXXX)"
    echo "fend: no --output-dir given, using $OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"

# ─── tool prereqs ────────────────────────────────────────────────────

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "fend: missing required tool: $1" >&2
        exit 1
    fi
}
for tool in curl cpio gzip tar zstd sha256sum file jq docker; do
    require_tool "$tool"
done

if ! docker info >/dev/null 2>&1; then
    echo "fend: docker daemon not running on the runner" >&2
    exit 1
fi

# ─── workspace ───────────────────────────────────────────────────────

WORK_DIR="$(mktemp -d -t fend-runtime-work-XXXXXX)"
STAGE_DIR="$(mktemp -d -t fend-runtime-stage-XXXXXX)"
trap 'rm -rf "$WORK_DIR" "$STAGE_DIR"' EXIT

KERNEL_PATH="$STAGE_DIR/vmlinuz"
INITRD_PATH="$STAGE_DIR/initrd"
ROOTFS_PATH="$STAGE_DIR/rootfs.img"

UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/noble/release/unpacked"
KERNEL_FILE="ubuntu-24.04-server-cloudimg-arm64-vmlinuz-generic"
ALPINE_VERSION="3.21"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/aarch64"

echo "fend: building runtime bundle for v${VERSION}"
echo "  fendd:  $FENDD_BIN"
echo "  stage:  $STAGE_DIR"
echo "  work:   $WORK_DIR"
echo "  output: $OUTPUT_DIR"

# ─── step 1: kernel ──────────────────────────────────────────────────

echo "fend: downloading Ubuntu 24.04 arm64 cloud kernel..."
curl -fSL --retry 5 --retry-all-errors --retry-delay 2 \
    "${UBUNTU_BASE}/${KERNEL_FILE}" -o "${WORK_DIR}/vmlinuz.gz"

if file "${WORK_DIR}/vmlinuz.gz" | grep -q "gzip"; then
    gunzip -f "${WORK_DIR}/vmlinuz.gz"
    mv "${WORK_DIR}/vmlinuz" "$KERNEL_PATH"
else
    mv "${WORK_DIR}/vmlinuz.gz" "$KERNEL_PATH"
fi

KERNEL_TYPE=$(file "$KERNEL_PATH")
if ! echo "$KERNEL_TYPE" | grep -q "ARM64"; then
    echo "fend: kernel is not ARM64 boot Image format: $KERNEL_TYPE" >&2
    exit 1
fi
echo "  kernel: $(du -h "$KERNEL_PATH" | cut -f1) (${KERNEL_TYPE})"

# ─── step 2: busybox + musl from Alpine ──────────────────────────────

echo "fend: downloading Alpine busybox + musl..."
curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
    "${ALPINE_MIRROR}/APKINDEX.tar.gz" -o "${WORK_DIR}/apkindex.tar.gz"
tar -xzf "${WORK_DIR}/apkindex.tar.gz" -C "$WORK_DIR" APKINDEX

BB_VER=$(grep -A1 "^P:busybox$" "$WORK_DIR/APKINDEX" | grep "^V:" | head -1 | cut -d: -f2)
[ -n "$BB_VER" ] || { echo "fend: could not resolve busybox version from APKINDEX" >&2; exit 1; }

curl -fsSL --retry 5 --retry-all-errors "${ALPINE_MIRROR}/busybox-${BB_VER}.apk" \
    -o "${WORK_DIR}/busybox.apk"
mkdir -p "${WORK_DIR}/bb_extract"
# .apk archives have a leading signature blob tar refuses to consume; using
# `|| true` lets us treat partial extraction as success and rely on the find
# below to confirm we got the busybox binary.
tar -xf "${WORK_DIR}/busybox.apk" -C "${WORK_DIR}/bb_extract" 2>/dev/null || true
BUSYBOX_PATH=$(find "${WORK_DIR}/bb_extract" -name "busybox" -type f | head -1)
[ -n "$BUSYBOX_PATH" ] || { echo "fend: failed to extract busybox" >&2; exit 1; }
chmod +x "$BUSYBOX_PATH"

MUSL_VER=$(grep -A1 "^P:musl$" "$WORK_DIR/APKINDEX" | grep "^V:" | head -1 | cut -d: -f2)
[ -n "$MUSL_VER" ] || { echo "fend: could not resolve musl version from APKINDEX" >&2; exit 1; }

curl -fsSL --retry 5 --retry-all-errors "${ALPINE_MIRROR}/musl-${MUSL_VER}.apk" \
    -o "${WORK_DIR}/musl.apk"
mkdir -p "${WORK_DIR}/musl_extract"
tar -xf "${WORK_DIR}/musl.apk" -C "${WORK_DIR}/musl_extract" 2>/dev/null || true
MUSL_PATH=$(find "${WORK_DIR}/musl_extract" -name "ld-musl-aarch64.so.1" -type f | head -1)
if [ -z "$MUSL_PATH" ]; then
    MUSL_PATH=$(find "${WORK_DIR}/musl_extract" -name "libc.musl*" -type f | head -1)
fi
[ -n "$MUSL_PATH" ] || { echo "fend: failed to extract musl libc" >&2; exit 1; }

echo "  busybox:  $(du -h "$BUSYBOX_PATH" | cut -f1) (alpine $BB_VER)"
echo "  musl:     $(du -h "$MUSL_PATH" | cut -f1) (alpine $MUSL_VER)"

# ─── step 3: Ubuntu kernel modules deb ───────────────────────────────

echo "fend: downloading kernel modules..."
KVER=$(strings "$KERNEL_PATH" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | head -1)
[ -n "$KVER" ] || KVER="6.8.0-100-generic"

KPKG_VER=$(echo "$KVER" | sed 's/-generic//' | sed 's/\(.*\)-\(.*\)/\1-\2.\2/')
MODULES_DEB="linux-modules-${KVER}_${KPKG_VER}_arm64.deb"

MODULES_DIR="${WORK_DIR}/modules"
mkdir -p "$MODULES_DIR"
DOWNLOADED=0
for URL in \
    "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/${MODULES_DEB}" \
    "http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-hwe-6.8/${MODULES_DEB}"
do
    if curl -fsSL --retry 3 --retry-all-errors "$URL" -o "${WORK_DIR}/modules.deb" 2>/dev/null; then
        DOWNLOADED=1
        break
    fi
done

if [ "$DOWNLOADED" -ne 1 ]; then
    echo "fend: failed to download kernel modules deb for $KVER" >&2
    exit 1
fi

mkdir -p "${WORK_DIR}/modules_extract"
( cd "${WORK_DIR}/modules_extract" && ar x "${WORK_DIR}/modules.deb" )
cd "${WORK_DIR}/modules_extract"
if [ -f data.tar.zst ]; then
    zstd -d -q data.tar.zst -o data.tar
elif [ -f data.tar.xz ]; then
    xz -d data.tar.xz
elif [ -f data.tar.gz ]; then
    gunzip data.tar.gz
fi
tar -xf data.tar
cd - >/dev/null

for mod in virtiofs fuse virtio_net virtio_pci virtio_ring virtio \
           vsock vmw_vsock_virtio_transport vmw_vsock_virtio_transport_common; do
    MOD_FILE=$(find "${WORK_DIR}/modules_extract" -name "${mod}.ko*" -type f 2>/dev/null | head -1)
    if [ -n "$MOD_FILE" ]; then
        case "$MOD_FILE" in
            *.zst) zstd -d -q "$MOD_FILE" -o "$MODULES_DIR/${mod}.ko" ;;
            *.xz)  xz -dc "$MOD_FILE" > "$MODULES_DIR/${mod}.ko" ;;
            *.gz)  gunzip -c "$MOD_FILE" > "$MODULES_DIR/${mod}.ko" ;;
            *)     cp "$MOD_FILE" "$MODULES_DIR/${mod}.ko" ;;
        esac
    fi
done
MOD_COUNT=$(find "$MODULES_DIR" -name '*.ko' | wc -l | tr -d ' ')
echo "  modules:  $MOD_COUNT (kver $KVER)"

# ─── step 4: optional Claude tool ────────────────────────────────────

CLAUDE_BIN=""
if [ "$SKIP_CLAUDE" != "1" ]; then
    echo "fend: downloading Claude Code linux-arm64 binary..."
    CLAUDE_DIST="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
    CLAUDE_VERSION=$(curl -fsSL --retry 3 "${CLAUDE_DIST}/latest" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$CLAUDE_VERSION" ]; then
        CLAUDE_BIN="${WORK_DIR}/claude"
        if curl -fSL --retry 3 --retry-all-errors \
            "${CLAUDE_DIST}/${CLAUDE_VERSION}/linux-arm64/claude" \
            -o "$CLAUDE_BIN" 2>/dev/null; then
            chmod +x "$CLAUDE_BIN"
            echo "  claude:   $(du -h "$CLAUDE_BIN" | cut -f1) ($CLAUDE_VERSION)"
        else
            echo "  claude:   download failed, continuing without it"
            CLAUDE_BIN=""
        fi
    else
        echo "  claude:   version probe failed, continuing without it"
    fi
fi

# ─── step 5: initramfs ───────────────────────────────────────────────

echo "fend: building initramfs..."
INITRD_ROOT="${WORK_DIR}/initrd_root"
mkdir -p "$INITRD_ROOT"/{bin,dev,proc,lib/modules,mnt/root}

cp "$MUSL_PATH" "$INITRD_ROOT/lib/ld-musl-aarch64.so.1"
chmod +x "$INITRD_ROOT/lib/ld-musl-aarch64.so.1"
cp "$BUSYBOX_PATH" "$INITRD_ROOT/bin/busybox"
chmod +x "$INITRD_ROOT/bin/busybox"
for cmd in sh mount insmod switch_root; do
    ln -sf busybox "$INITRD_ROOT/bin/$cmd"
done

cp "$MODULES_DIR"/*.ko "$INITRD_ROOT/lib/modules/" 2>/dev/null || true

cat > "$INITRD_ROOT/init" << 'INIT_EOF'
#!/bin/sh
/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
for m in /lib/modules/*.ko; do
    [ -f "$m" ] && /bin/insmod "$m" 2>/dev/null
done
/bin/mount -t ext4 /dev/vda /mnt/root
exec /bin/switch_root /mnt/root /usr/local/bin/fendd
INIT_EOF
chmod +x "$INITRD_ROOT/init"

( cd "$INITRD_ROOT" && find . | cpio -o -H newc 2>/dev/null | gzip > "$INITRD_PATH" )
echo "  initrd:   $(du -h "$INITRD_PATH" | cut -f1)"

# ─── step 6: rootfs.img via Docker ───────────────────────────────────

echo "fend: building rootfs.img via docker..."
ROOTFS_BUILD="${WORK_DIR}/rootfs_build"
mkdir -p "$ROOTFS_BUILD"
cp "$FENDD_BIN" "$ROOTFS_BUILD/fendd"
cp -r "$MODULES_DIR" "$ROOTFS_BUILD/modules"
if [ -n "$CLAUDE_BIN" ] && [ -f "$CLAUDE_BIN" ]; then
    cp "$CLAUDE_BIN" "$ROOTFS_BUILD/claude"
fi

cat > "$ROOTFS_BUILD/Dockerfile" <<'DOCKER_EOF'
FROM ubuntu:24.04 AS rootfs
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates openssh-client kmod \
    isc-dhcp-client iproute2 iputils-ping e2fsprogs \
    && rm -rf /var/lib/apt/lists/*
RUN if id -u 1000 >/dev/null 2>&1; then \
      existing=$(getent passwd 1000 | cut -d: -f1); \
      usermod -l user -d /home/user -m -s /bin/bash "$existing"; \
      groupmod -n user "$existing" 2>/dev/null || true; \
    else \
      useradd -m -u 1000 -s /bin/bash user; \
    fi
COPY fendd /usr/local/bin/fendd
RUN chmod +x /usr/local/bin/fendd
COPY modules/ /lib/modules/
RUN mkdir -p /workspace /opt/tools /home/user/.npm /home/user/.local/bin /tmp/claude-staged \
    && chown -R 1000:1000 /home/user
RUN echo "nameserver 192.168.64.1" > /etc/resolv.conf.fend
RUN printf '127.0.0.1 localhost fend\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts.fend
RUN printf '#!/bin/sh\ncase "$1" in\n  bound|renew)\n    ip addr add "$ip/$mask" dev "$interface" 2>/dev/null\n    [ -n "$router" ] && ip route add default via "$router" dev "$interface" 2>/dev/null\n    [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf\n    ;;\nesac\n' > /bin/simple_dhcp.sh \
    && chmod +x /bin/simple_dhcp.sh
RUN [ -f /usr/bin/env ] || ln -sf /bin/env /usr/bin/env
DOCKER_EOF

docker build --platform linux/arm64 -t fend-rootfs-builder "$ROOTFS_BUILD" >/dev/null

CONTAINER_ID=$(docker create --platform linux/arm64 fend-rootfs-builder /bin/true)
ROOTFS_TAR="${WORK_DIR}/rootfs.tar"
docker export "$CONTAINER_ID" -o "$ROOTFS_TAR"
docker rm "$CONTAINER_ID" >/dev/null

TAR_SIZE_MB=$(du -m "$ROOTFS_TAR" | cut -f1)
IMG_SIZE_MB=$(( TAR_SIZE_MB + TAR_SIZE_MB / 5 ))
[ "$IMG_SIZE_MB" -lt 512 ] && IMG_SIZE_MB=512

cat > "$ROOTFS_BUILD/Dockerfile.mkfs" <<'MKFS_EOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs \
    && rm -rf /var/lib/apt/lists/*
MKFS_EOF
docker build --platform linux/arm64 -t fend-mkfs -f "$ROOTFS_BUILD/Dockerfile.mkfs" "$ROOTFS_BUILD" >/dev/null

docker run --rm --platform linux/arm64 \
    -v "${ROOTFS_TAR}:/rootfs.tar:ro" \
    -v "${STAGE_DIR}:/output" \
    fend-mkfs /bin/bash -c "
        mkdir -p /rootfs_dir
        tar -xf /rootfs.tar -C /rootfs_dir
        rm -rf /rootfs_dir/.dockerenv /rootfs_dir/proc/* /rootfs_dir/sys/* /rootfs_dir/dev/*
        mkdir -p /rootfs_dir/proc /rootfs_dir/sys /rootfs_dir/dev /rootfs_dir/dev/pts /rootfs_dir/tmp
        chmod 1777 /rootfs_dir/tmp
        if [ -f /rootfs_dir/etc/hosts.fend ]; then
            cp /rootfs_dir/etc/hosts.fend /rootfs_dir/etc/hosts
            rm /rootfs_dir/etc/hosts.fend
        fi
        mke2fs -t ext4 -d /rootfs_dir -L fend-rootfs -m 1 -N 100000 \
            /output/rootfs.img ${IMG_SIZE_MB}M
    " >/dev/null

docker rmi fend-rootfs-builder fend-mkfs >/dev/null 2>&1 || true

[ -f "$ROOTFS_PATH" ] || { echo "fend: rootfs.img was not created" >&2; exit 1; }
echo "  rootfs:   $(du -h "$ROOTFS_PATH" | cut -f1) (mke2fs ${IMG_SIZE_MB}MB)"

# ─── step 7: manifest ────────────────────────────────────────────────

echo "fend: writing manifest..."
KERNEL_SHA=$(sha256sum "$KERNEL_PATH" | cut -d' ' -f1)
INITRD_SHA=$(sha256sum "$INITRD_PATH" | cut -d' ' -f1)
ROOTFS_SHA=$(sha256sum "$ROOTFS_PATH" | cut -d' ' -f1)
FENDD_SHA=$(sha256sum "$FENDD_BIN" | cut -d' ' -f1)

MANIFEST_PATH="$STAGE_DIR/manifest.json"
jq -n \
    --arg version "$VERSION" \
    --arg target "darwin-arm64" \
    --arg kver "$KVER" \
    --arg kernel_source "${UBUNTU_BASE}/${KERNEL_FILE}" \
    --arg fendd_sha "$FENDD_SHA" \
    --arg kernel_sha "$KERNEL_SHA" \
    --arg initrd_sha "$INITRD_SHA" \
    --arg rootfs_sha "$ROOTFS_SHA" \
    '{
        schema_version: 1,
        runtime_version: $version,
        target: $target,
        kernel_version: $kver,
        kernel_source: $kernel_source,
        fendd_sha256: $fendd_sha,
        files: {
            "vmlinuz":    { sha256: $kernel_sha },
            "initrd":     { sha256: $initrd_sha },
            "rootfs.img": { sha256: $rootfs_sha }
        }
    }' > "$MANIFEST_PATH"

# ─── step 8: tar + zstd bundle ───────────────────────────────────────

BUNDLE_NAME="fend-runtime-darwin-arm64-v${VERSION}.tar.zst"
BUNDLE_PATH="$OUTPUT_DIR/$BUNDLE_NAME"

echo "fend: compressing bundle..."
# Deterministic ordering: vmlinuz, initrd, rootfs.img, manifest.json.
( cd "$STAGE_DIR" && tar --owner=0 --group=0 --mtime='@0' --sort=name \
    -cf - vmlinuz initrd rootfs.img manifest.json \
    | zstd -19 -T0 -q -o "$BUNDLE_PATH" )

BUNDLE_SHA=$(sha256sum "$BUNDLE_PATH" | cut -d' ' -f1)
echo "$BUNDLE_SHA  $BUNDLE_NAME" > "${BUNDLE_PATH}.sha256"

# Also copy the manifest to the output dir as a sidecar so consumers
# can read versions without untarring.
cp "$MANIFEST_PATH" "$OUTPUT_DIR/manifest.json"

echo ""
echo "fend: runtime bundle ready"
echo "  bundle:  $BUNDLE_PATH"
echo "  sha256:  $BUNDLE_SHA"
echo "  size:    $(du -h "$BUNDLE_PATH" | cut -f1)"
echo ""
