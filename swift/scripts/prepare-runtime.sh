#!/bin/bash
# Downloads a Linux kernel and builds runtime artifacts for fend VMs.
# Stores everything in ~/.fend/runtime/
#
# Produces:
#   vmlinuz    — Ubuntu ARM64 kernel (~10MB)
#   initrd     — Tiny initramfs: busybox + modules + /init script (~2MB)
#   rootfs.img — Ubuntu 24.04 ext4 disk image with git + fendd (~1-1.5GB, APFS-sparse)
#
# Requirements: curl, cpio, gzip, Docker (for rootfs.img)
# Works on macOS (Apple Silicon)

set -euo pipefail

# Resolve paths early (before any cd commands change cwd)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FEND_HOME="${HOME}/.fend"
RUNTIME_DIR="${FEND_HOME}/runtime"
WORK_DIR="${FEND_HOME}/tmp/build-runtime"

# Ubuntu 24.04 Noble - kernel known to work with Virtualization.framework
UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/noble/release/unpacked"
KERNEL_FILE="ubuntu-24.04-server-cloudimg-arm64-vmlinuz-generic"

# Alpine Linux for static busybox + musl
ALPINE_VERSION="3.21"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/aarch64"

echo "fend: preparing runtime files..."
echo "  target: ${RUNTIME_DIR}"

mkdir -p "${RUNTIME_DIR}" "${WORK_DIR}"

# ─── Step 1: Download Ubuntu kernel ───────────────────────────────────

KERNEL_PATH="${RUNTIME_DIR}/vmlinuz"

if [ -f "${KERNEL_PATH}" ]; then
    KERNEL_TYPE=$(file "${KERNEL_PATH}" 2>/dev/null || echo "")
    if echo "${KERNEL_TYPE}" | grep -q "PE32+"; then
        echo "  kernel: existing kernel is PE32+ EFI (incompatible), re-downloading..."
        rm -f "${KERNEL_PATH}"
    else
        echo "  kernel: already exists, skipping download"
    fi
fi

if [ ! -f "${KERNEL_PATH}" ]; then
    echo "  kernel: downloading Ubuntu 24.04 cloud kernel..."

    curl -fSL "${UBUNTU_BASE}/${KERNEL_FILE}" -o "${WORK_DIR}/vmlinuz.gz"

    FILE_TYPE=$(file "${WORK_DIR}/vmlinuz.gz" 2>/dev/null || echo "")
    if echo "${FILE_TYPE}" | grep -q "gzip"; then
        echo "  kernel: decompressing..."
        gunzip -f "${WORK_DIR}/vmlinuz.gz"
        mv "${WORK_DIR}/vmlinuz" "${KERNEL_PATH}"
    else
        mv "${WORK_DIR}/vmlinuz.gz" "${KERNEL_PATH}"
    fi

    KERNEL_TYPE=$(file "${KERNEL_PATH}" 2>/dev/null || echo "")
    if echo "${KERNEL_TYPE}" | grep -q "ARM64"; then
        echo "  kernel: format OK (ARM64 boot executable Image)"
    elif echo "${KERNEL_TYPE}" | grep -q "PE32+"; then
        echo "  ERROR: kernel is PE32+ EFI format (incompatible with VZLinuxBootLoader)"
        rm -f "${KERNEL_PATH}"
        exit 1
    else
        echo "  kernel: format: ${KERNEL_TYPE}"
        echo "  warning: unexpected format, boot may fail"
    fi

    echo "  kernel: installed ($(du -h "${KERNEL_PATH}" | cut -f1))"
fi

# ─── Step 2: Download static busybox + musl ──────────────────────────

BUSYBOX_PATH="${WORK_DIR}/busybox"
MUSL_PATH="${WORK_DIR}/ld-musl-aarch64.so.1"

if [ ! -f "${BUSYBOX_PATH}" ] || [ ! -f "${MUSL_PATH}" ]; then
    echo "  busybox: downloading Alpine packages..."

    curl -fsSL "${ALPINE_MIRROR}/APKINDEX.tar.gz" -o "${WORK_DIR}/apkindex.tar.gz"
    tar -xzf "${WORK_DIR}/apkindex.tar.gz" -C "${WORK_DIR}" APKINDEX 2>/dev/null || true

    BB_VER=$(grep -A1 "^P:busybox$" "${WORK_DIR}/APKINDEX" 2>/dev/null | grep "^V:" | head -1 | cut -d: -f2)
    if [ -n "${BB_VER}" ]; then
        echo "  busybox: downloading busybox-${BB_VER}..."
        curl -fsSL "${ALPINE_MIRROR}/busybox-${BB_VER}.apk" -o "${WORK_DIR}/busybox.apk"
        mkdir -p "${WORK_DIR}/bb_extract"
        cd "${WORK_DIR}/bb_extract"
        tar -xf "${WORK_DIR}/busybox.apk" 2>/dev/null || true
        BB=$(find "${WORK_DIR}/bb_extract" -name "busybox" -type f 2>/dev/null | head -1)
        if [ -n "${BB}" ]; then
            cp "${BB}" "${BUSYBOX_PATH}"
            chmod +x "${BUSYBOX_PATH}"
        fi
        cd "${WORK_DIR}"
        rm -rf "${WORK_DIR}/bb_extract"
    fi

    MUSL_VER=$(grep -A1 "^P:musl$" "${WORK_DIR}/APKINDEX" 2>/dev/null | grep "^V:" | head -1 | cut -d: -f2)
    if [ -n "${MUSL_VER}" ]; then
        echo "  musl: downloading musl-${MUSL_VER}..."
        curl -fsSL "${ALPINE_MIRROR}/musl-${MUSL_VER}.apk" -o "${WORK_DIR}/musl.apk"
        mkdir -p "${WORK_DIR}/musl_extract"
        cd "${WORK_DIR}/musl_extract"
        tar -xf "${WORK_DIR}/musl.apk" 2>/dev/null || true
        MUSL=$(find "${WORK_DIR}/musl_extract" -name "ld-musl-aarch64.so.1" -type f 2>/dev/null | head -1)
        if [ -z "${MUSL}" ]; then
            MUSL=$(find "${WORK_DIR}/musl_extract" -name "libc.musl*" -type f 2>/dev/null | head -1)
        fi
        if [ -n "${MUSL}" ]; then
            cp "${MUSL}" "${MUSL_PATH}"
            chmod +x "${MUSL_PATH}"
        fi
        cd "${WORK_DIR}"
        rm -rf "${WORK_DIR}/musl_extract"
    fi

    if [ ! -f "${BUSYBOX_PATH}" ]; then
        echo "  ERROR: could not download busybox"
        exit 1
    fi
    if [ ! -f "${MUSL_PATH}" ]; then
        echo "  ERROR: could not download musl libc"
        exit 1
    fi

    echo "  busybox: installed ($(du -h "${BUSYBOX_PATH}" | cut -f1))"
    echo "  musl: installed ($(du -h "${MUSL_PATH}" | cut -f1))"
fi

# ─── Step 3: Download kernel modules ─────────────────────────────────

MODULES_DIR="${WORK_DIR}/modules"

if [ ! -d "${MODULES_DIR}" ]; then
    echo "  modules: downloading Ubuntu kernel modules..."

    KVER=$(strings "${KERNEL_PATH}" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' | head -1)
    if [ -z "${KVER}" ]; then
        KVER="6.8.0-100-generic"
        echo "  modules: could not detect kernel version, assuming ${KVER}"
    else
        echo "  modules: detected kernel version ${KVER}"
    fi

    KPKG_VER=$(echo "${KVER}" | sed 's/-generic//' | sed 's/\(.*\)-\(.*\)/\1-\2.\2/')
    MODULES_DEB="linux-modules-${KVER}_${KPKG_VER}_arm64.deb"
    MODULES_URL="http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux/${MODULES_DEB}"

    echo "  modules: trying ${MODULES_URL}..."
    if curl -fsSL "${MODULES_URL}" -o "${WORK_DIR}/modules.deb" 2>/dev/null; then
        echo "  modules: downloaded, extracting needed modules..."
    else
        echo "  modules: ports.ubuntu.com failed, trying alternate..."
        MODULES_URL="http://ports.ubuntu.com/ubuntu-ports/pool/main/l/linux-hwe-6.8/${MODULES_DEB}"
        if ! curl -fsSL "${MODULES_URL}" -o "${WORK_DIR}/modules.deb" 2>/dev/null; then
            echo "  modules: WARNING - could not download kernel modules"
            mkdir -p "${MODULES_DIR}"
            touch "${MODULES_DIR}/.no-modules"
        fi
    fi

    if [ -f "${WORK_DIR}/modules.deb" ]; then
        mkdir -p "${WORK_DIR}/modules_extract"
        cd "${WORK_DIR}/modules_extract"
        ar x "${WORK_DIR}/modules.deb" 2>/dev/null || true
        if [ -f data.tar.zst ]; then
            zstd -d data.tar.zst -o data.tar 2>/dev/null || tar -xf data.tar.zst 2>/dev/null || true
        elif [ -f data.tar.xz ]; then
            xz -d data.tar.xz 2>/dev/null || true
        elif [ -f data.tar.gz ]; then
            gunzip data.tar.gz 2>/dev/null || true
        fi

        if [ -f data.tar ]; then
            tar -xf data.tar 2>/dev/null || true
        fi

        mkdir -p "${MODULES_DIR}"

        for mod in virtiofs fuse virtio_net virtio_pci virtio_ring virtio \
                   vsock vmw_vsock_virtio_transport vmw_vsock_virtio_transport_common; do
            MOD_FILE=$(find "${WORK_DIR}/modules_extract" -name "${mod}.ko*" -type f 2>/dev/null | head -1)
            if [ -n "${MOD_FILE}" ]; then
                case "${MOD_FILE}" in
                    *.zst)
                        zstd -d "${MOD_FILE}" -o "${MODULES_DIR}/${mod}.ko" 2>/dev/null
                        ;;
                    *.xz)
                        xz -dc "${MOD_FILE}" > "${MODULES_DIR}/${mod}.ko" 2>/dev/null
                        ;;
                    *.gz)
                        gunzip -c "${MOD_FILE}" > "${MODULES_DIR}/${mod}.ko" 2>/dev/null
                        ;;
                    *)
                        cp "${MOD_FILE}" "${MODULES_DIR}/${mod}.ko"
                        ;;
                esac
                echo "  modules: extracted ${mod}.ko"
            fi
        done

        cd "${WORK_DIR}"
        rm -rf "${WORK_DIR}/modules_extract" "${WORK_DIR}/modules.deb"
    fi
fi

# ─── Step 4: Download Claude Code binary ──────────────────────────────

CLAUDE_DIR="${FEND_HOME}/tools/claude"

if [ ! -f "${CLAUDE_DIR}/claude" ]; then
    echo "  claude: downloading Claude Code Linux arm64 binary..."

    CLAUDE_DIST="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

    CLAUDE_VERSION=$(curl -fsSL "${CLAUDE_DIST}/latest" 2>/dev/null | tr -d '[:space:]')
    if [ -z "${CLAUDE_VERSION}" ]; then
        echo "  claude: WARNING - could not fetch latest version, skipping"
    else
        echo "  claude: latest version: ${CLAUDE_VERSION}"
        mkdir -p "${CLAUDE_DIR}"

        if curl -fSL "${CLAUDE_DIST}/${CLAUDE_VERSION}/linux-arm64/claude" -o "${CLAUDE_DIR}/claude" 2>/dev/null; then
            chmod +x "${CLAUDE_DIR}/claude"
            echo "  claude: installed ($(du -h "${CLAUDE_DIR}/claude" | cut -f1))"
        else
            echo "  claude: WARNING - download failed, skipping"
            rm -f "${CLAUDE_DIR}/claude"
        fi
    fi
else
    echo "  claude: already exists ($(du -h "${CLAUDE_DIR}/claude" | cut -f1)), skipping"
fi

# ─── Step 5: Locate fendd binary ─────────────────────────────────────

FENDD_BIN="${PROJECT_ROOT}/fendd/target/aarch64-unknown-linux-musl/release/fendd"

if [ ! -f "${FENDD_BIN}" ]; then
    echo "  fendd: not found at ${FENDD_BIN}"
    echo "  fendd: build it first: cd fendd && cargo zigbuild --target aarch64-unknown-linux-musl --release"
    exit 1
fi

FENDD_TYPE=$(file "${FENDD_BIN}" 2>/dev/null || echo "")
if ! echo "${FENDD_TYPE}" | grep -q "ELF 64-bit.*aarch64"; then
    echo "  ERROR: fendd is not an aarch64 ELF binary"
    echo "  got: ${FENDD_TYPE}"
    exit 1
fi

echo "  fendd: found ($(du -h "${FENDD_BIN}" | cut -f1))"

# ─── Step 6: Build tiny initramfs ─────────────────────────────────────

INITRD_PATH="${RUNTIME_DIR}/initrd"

echo "  initrd: building tiny initramfs (busybox + modules + init)..."

INITRD_ROOT="${WORK_DIR}/initrd_root"
rm -rf "${INITRD_ROOT}"
mkdir -p "${INITRD_ROOT}"/{bin,dev,proc,lib/modules,mnt/root}

# Copy musl dynamic linker (needed for busybox)
cp "${MUSL_PATH}" "${INITRD_ROOT}/lib/ld-musl-aarch64.so.1"
chmod +x "${INITRD_ROOT}/lib/ld-musl-aarch64.so.1"

# Copy busybox + create essential symlinks
cp "${BUSYBOX_PATH}" "${INITRD_ROOT}/bin/busybox"
chmod +x "${INITRD_ROOT}/bin/busybox"
for cmd in sh mount insmod switch_root; do
    ln -sf busybox "${INITRD_ROOT}/bin/${cmd}"
done

# Copy kernel modules
if [ -d "${MODULES_DIR}" ] && [ ! -f "${MODULES_DIR}/.no-modules" ]; then
    cp "${MODULES_DIR}"/*.ko "${INITRD_ROOT}/lib/modules/" 2>/dev/null || true
    echo "  initrd: included $(ls "${INITRD_ROOT}/lib/modules/"*.ko 2>/dev/null | wc -l | tr -d ' ') kernel modules"
fi

# Create /init script — loads modules, mounts root disk, switch_root to fendd
cat > "${INITRD_ROOT}/init" << 'INIT_EOF'
#!/bin/sh
/bin/mount -t devtmpfs devtmpfs /dev
/bin/mount -t proc proc /proc
for m in /lib/modules/*.ko; do
    [ -f "$m" ] && /bin/insmod "$m" 2>/dev/null
done
/bin/mount -t ext4 /dev/vda /mnt/root
exec /bin/switch_root /mnt/root /usr/local/bin/fendd
INIT_EOF
chmod +x "${INITRD_ROOT}/init"

# Build the initramfs cpio archive
cd "${INITRD_ROOT}"
find . | cpio -o -H newc 2>/dev/null | gzip > "${INITRD_PATH}"

echo "  initrd: built ($(du -h "${INITRD_PATH}" | cut -f1))"

# ─── Step 7: Build rootfs.img via Docker ──────────────────────────────

ROOTFS_PATH="${RUNTIME_DIR}/rootfs.img"

if [ -f "${ROOTFS_PATH}" ]; then
    echo "  rootfs: already exists ($(du -h "${ROOTFS_PATH}" | cut -f1)), skipping"
    echo "  rootfs: delete ${ROOTFS_PATH} to rebuild"
else
    echo "  rootfs: building Ubuntu 24.04 ext4 disk image via Docker..."

    if ! command -v docker &>/dev/null; then
        echo "  ERROR: Docker is required to build rootfs.img"
        echo "  Install Docker Desktop for Mac: https://www.docker.com/products/docker-desktop/"
        exit 1
    fi

    if ! docker info &>/dev/null; then
        echo "  ERROR: Docker daemon is not running"
        echo "  Start Docker Desktop and try again."
        exit 1
    fi

    ROOTFS_BUILD="${WORK_DIR}/rootfs_build"
    rm -rf "${ROOTFS_BUILD}"
    mkdir -p "${ROOTFS_BUILD}"

    # Copy fendd binary and kernel modules into build context
    cp "${FENDD_BIN}" "${ROOTFS_BUILD}/fendd"
    if [ -d "${MODULES_DIR}" ] && [ ! -f "${MODULES_DIR}/.no-modules" ]; then
        cp -r "${MODULES_DIR}" "${ROOTFS_BUILD}/modules"
    else
        mkdir -p "${ROOTFS_BUILD}/modules"
    fi

    # Create Dockerfile
    cat > "${ROOTFS_BUILD}/Dockerfile" << 'DOCKER_EOF'
FROM ubuntu:24.04 AS rootfs

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install essential packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    openssh-client \
    kmod \
    isc-dhcp-client \
    iproute2 \
    iputils-ping \
    e2fsprogs \
    && rm -rf /var/lib/apt/lists/*

# Ensure user:1000 exists (Ubuntu 24.04 may already have 'ubuntu' at UID 1000)
RUN if id -u 1000 >/dev/null 2>&1; then \
      existing=$(getent passwd 1000 | cut -d: -f1); \
      usermod -l user -d /home/user -m -s /bin/bash "$existing"; \
      groupmod -n user "$existing" 2>/dev/null || true; \
    else \
      useradd -m -u 1000 -s /bin/bash user; \
    fi

# Install fendd as PID 1 entry point
COPY fendd /usr/local/bin/fendd
RUN chmod +x /usr/local/bin/fendd

# Copy kernel modules
COPY modules/ /lib/modules/

# Pre-create expected directories
RUN mkdir -p /workspace /opt/tools /home/user/.npm /home/user/.local/bin /tmp/claude-staged \
    && chown -R 1000:1000 /home/user

# Configure DNS and hostname resolution
RUN echo "nameserver 192.168.64.1" > /etc/resolv.conf.fend
# /etc/hosts is bind-mounted read-only during build (OrbStack/Docker Desktop),
# so write to a staging file — the mke2fs step populates it into the final image
RUN printf '127.0.0.1 localhost fend\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts.fend

# Simple DHCP hook script (fallback for busybox udhcpc if ever needed)
RUN printf '#!/bin/sh\ncase "$1" in\n  bound|renew)\n    ip addr add "$ip/$mask" dev "$interface" 2>/dev/null\n    [ -n "$router" ] && ip route add default via "$router" dev "$interface" 2>/dev/null\n    [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf\n    ;;\nesac\n' > /bin/simple_dhcp.sh \
    && chmod +x /bin/simple_dhcp.sh

# /usr/bin/env symlink (usually already exists in Ubuntu, but ensure it)
RUN [ -f /usr/bin/env ] || ln -sf /bin/env /usr/bin/env

# --- Second stage: create ext4 image from rootfs ---
FROM rootfs AS builder

# Calculate rootfs size and create ext4 image
# mke2fs -d populates an ext4 image from a directory without needing root/loop
RUN du -sm / --exclude=/proc --exclude=/sys --exclude=/dev 2>/dev/null | awk '{print $1}' > /tmp/rootfs_size

# We'll export the rootfs directory and create the image on the host
DOCKER_EOF

    echo "  rootfs: building Docker image..."
    docker build --platform linux/arm64 -t fend-rootfs-builder "${ROOTFS_BUILD}" 2>&1 | while IFS= read -r line; do
        echo "  rootfs: ${line}"
    done

    echo "  rootfs: exporting filesystem..."

    # Create a container and export its filesystem as a tar
    CONTAINER_ID=$(docker create --platform linux/arm64 fend-rootfs-builder /bin/true)

    ROOTFS_TAR="${WORK_DIR}/rootfs.tar"
    docker export "${CONTAINER_ID}" -o "${ROOTFS_TAR}"
    docker rm "${CONTAINER_ID}" >/dev/null

    # Determine image size: exported tar size + 20% headroom, minimum 512MB
    TAR_SIZE_MB=$(du -m "${ROOTFS_TAR}" | cut -f1)
    IMG_SIZE_MB=$(( TAR_SIZE_MB + TAR_SIZE_MB / 5 ))
    if [ "${IMG_SIZE_MB}" -lt 512 ]; then
        IMG_SIZE_MB=512
    fi
    echo "  rootfs: tar=${TAR_SIZE_MB}MB, image=${IMG_SIZE_MB}MB"

    # Use Docker to create the ext4 image (mke2fs -d needs Linux)
    cat > "${ROOTFS_BUILD}/Dockerfile.mkfs" << MKFS_EOF
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs && rm -rf /var/lib/apt/lists/*
MKFS_EOF

    docker build --platform linux/arm64 -t fend-mkfs -f "${ROOTFS_BUILD}/Dockerfile.mkfs" "${ROOTFS_BUILD}" 2>&1 | while IFS= read -r line; do
        echo "  rootfs: ${line}"
    done

    echo "  rootfs: creating ext4 image (${IMG_SIZE_MB}MB)..."
    docker run --rm --platform linux/arm64 \
        -v "${ROOTFS_TAR}:/rootfs.tar:ro" \
        -v "${RUNTIME_DIR}:/output" \
        fend-mkfs /bin/bash -c "
            mkdir -p /rootfs_dir
            tar -xf /rootfs.tar -C /rootfs_dir
            # Remove Docker artifacts
            rm -rf /rootfs_dir/.dockerenv /rootfs_dir/proc/* /rootfs_dir/sys/* /rootfs_dir/dev/*
            # Ensure essential dirs exist but are empty (will be mounted by fendd)
            mkdir -p /rootfs_dir/proc /rootfs_dir/sys /rootfs_dir/dev /rootfs_dir/dev/pts /rootfs_dir/tmp
            chmod 1777 /rootfs_dir/tmp
            # /etc/hosts was read-only during build — install the staged version now
            if [ -f /rootfs_dir/etc/hosts.fend ]; then
                cp /rootfs_dir/etc/hosts.fend /rootfs_dir/etc/hosts
                rm /rootfs_dir/etc/hosts.fend
            fi
            # Create the ext4 image using mke2fs -d (no loop mount needed)
            mke2fs -t ext4 -d /rootfs_dir -L fend-rootfs \
                -m 1 -N 100000 \
                /output/rootfs.img ${IMG_SIZE_MB}M
        " 2>&1 | while IFS= read -r line; do
        echo "  rootfs: ${line}"
    done

    # Clean up
    rm -f "${ROOTFS_TAR}"
    rm -rf "${ROOTFS_BUILD}"
    docker rmi fend-rootfs-builder fend-mkfs 2>/dev/null || true

    if [ -f "${ROOTFS_PATH}" ]; then
        echo "  rootfs: built ($(du -h "${ROOTFS_PATH}" | cut -f1))"
    else
        echo "  ERROR: rootfs.img was not created"
        exit 1
    fi
fi

# ─── Cleanup ──────────────────────────────────────────────────────────

rm -rf "${WORK_DIR}"

echo ""
echo "fend: runtime ready"
echo "  kernel:  ${KERNEL_PATH}"
echo "  initrd:  ${INITRD_PATH}"
echo "  rootfs:  ${ROOTFS_PATH}"
echo ""
echo "You can now run: fend <command>"
