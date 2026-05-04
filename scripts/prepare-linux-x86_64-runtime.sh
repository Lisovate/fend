#!/usr/bin/env bash
# Build x86_64 Linux runtime artifacts for the Phase 1 QEMU/KVM spike.
#
# Produces:
#   ~/.fend/runtime/linux-x86_64/vmlinuz
#   ~/.fend/runtime/linux-x86_64/initrd
#   ~/.fend/runtime/linux-x86_64/rootfs.img
#
# This is intentionally separate from swift/scripts/prepare-runtime.sh so the
# current macOS Apple Silicon runtime builder stays unchanged while Linux is
# being proven.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/prepare-linux-x86_64-runtime.sh [--check]

Options:
  --check                   Validate local prerequisites without downloading or
                            building runtime artifacts.

Environment:
  FEND_HOME                 Base fend state dir. Default: ~/.fend
  FEND_RUNTIME_DIR          Output dir. Default: ~/.fend/runtime/linux-x86_64
  FEND_WORK_DIR             Temporary build dir. Default: ~/.fend/tmp/build-linux-x86_64-runtime
  FENDD_BIN                 Existing x86_64-unknown-linux-musl fendd binary.
  FEND_BUILD_FENDD=1        Build fendd automatically if FENDD_BIN is missing.
  FEND_REBUILD_ROOTFS=1     Rebuild rootfs.img even if it already exists.
  FEND_FORCE_DOWNLOADS=1    Re-download kernel/initrd even if they already exist.
  FEND_CLAUDE_DIR           Optional Claude install dir. Default: ~/.fend/tools/claude-linux-x64
  FEND_SKIP_CLAUDE=1        Skip optional Claude Code linux-x64 download.

Requirements:
  curl, Docker, file, strings, and a built x86_64-unknown-linux-musl fendd.

Typical flow:
  rustup target add x86_64-unknown-linux-musl
  cd fendd && cargo build --release --target x86_64-unknown-linux-musl --bin fendd
  cd ..
  scripts/prepare-linux-x86_64-runtime.sh
  scripts/linux-qemu-spike.sh /path/to/project
EOF
}

CHECK_ONLY=0
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --check|check)
        CHECK_ONLY=1
        shift
        ;;
    "")
        ;;
    *)
        printf 'error unknown argument: %s\n' "$1" >&2
        usage
        exit 1
        ;;
esac

if [[ "$#" -gt 0 ]]; then
    printf 'error unexpected argument: %s\n' "$1" >&2
    usage
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FEND_HOME="${FEND_HOME:-"${HOME}/.fend"}"
RUNTIME_DIR="${FEND_RUNTIME_DIR:-"${FEND_HOME}/runtime/linux-x86_64"}"
WORK_DIR="${FEND_WORK_DIR:-"${FEND_HOME}/tmp/build-linux-x86_64-runtime"}"

UBUNTU_BASE="${FEND_UBUNTU_BASE:-"https://cloud-images.ubuntu.com/releases/noble/release/unpacked"}"
KERNEL_FILE="ubuntu-24.04-server-cloudimg-amd64-vmlinuz-generic"
INITRD_FILE="ubuntu-24.04-server-cloudimg-amd64-initrd-generic"
DOCKER_PLATFORM="linux/amd64"
RUST_TARGET="x86_64-unknown-linux-musl"
FENDD_BIN="${FENDD_BIN:-"${PROJECT_ROOT}/fendd/target/${RUST_TARGET}/release/fendd"}"
CLAUDE_DIR="${FEND_CLAUDE_DIR:-"${FEND_HOME}/tools/claude-linux-x64"}"

KERNEL_PATH="${RUNTIME_DIR}/vmlinuz"
INITRD_PATH="${RUNTIME_DIR}/initrd"
ROOTFS_PATH="${RUNTIME_DIR}/rootfs.img"
METADATA_PATH="${RUNTIME_DIR}/metadata.env"

info() {
    printf 'info  %s\n' "$*"
}

detail() {
    printf '      %-10s %s\n' "$1" "$2"
}

die() {
    printf 'error %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "missing required command: $1"
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "missing sha256sum or shasum for checksum verification"
    fi
}

download() {
    local url="$1"
    local dest="$2"

    mkdir -p "$(dirname "${dest}")"
    curl -fL --retry 3 --retry-delay 2 "${url}" -o "${dest}.tmp"
    mv "${dest}.tmp" "${dest}"
}

ensure_ubuntu_sums() {
    if [[ ! -f "${WORK_DIR}/SHA256SUMS" || "${FEND_FORCE_DOWNLOADS:-0}" == "1" ]]; then
        info "downloading Ubuntu SHA256SUMS"
        download "${UBUNTU_BASE}/SHA256SUMS" "${WORK_DIR}/SHA256SUMS"
    fi
}

verify_ubuntu_artifact() {
    local name="$1"
    local path="$2"
    local expected actual

    expected="$(
        awk -v f="${name}" '
            {
                n = $2
                sub(/^\*/, "", n)
                if (n == f) {
                    print $1
                    exit
                }
            }
        ' "${WORK_DIR}/SHA256SUMS"
    )"

    if [[ -z "${expected}" ]]; then
        die "Ubuntu SHA256SUMS did not contain ${name}"
    fi

    actual="$(sha256_file "${path}")"
    if [[ "${actual}" != "${expected}" ]]; then
        rm -f "${path}"
        die "checksum mismatch for ${name}"
    fi
}

download_ubuntu_artifact() {
    local name="$1"
    local path="$2"
    local label="$3"

    if [[ -f "${path}" && "${FEND_FORCE_DOWNLOADS:-0}" != "1" ]]; then
        detail "${label}" "already exists ($(du -h "${path}" | cut -f1))"
        return
    fi

    info "downloading ${label}"
    download "${UBUNTU_BASE}/${name}" "${path}"
    verify_ubuntu_artifact "${name}" "${path}"
    detail "${label}" "installed ($(du -h "${path}" | cut -f1))"
}

detect_kernel_version() {
    strings "${KERNEL_PATH}" 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic' \
        | head -1 || true
}

ensure_fendd() {
    if [[ ! -f "${FENDD_BIN}" && "${FEND_BUILD_FENDD:-0}" == "1" ]]; then
        require_cmd cargo
        info "building fendd for ${RUST_TARGET}"
        (
            cd "${PROJECT_ROOT}/fendd"
            cargo build --release --target "${RUST_TARGET}" --bin fendd
        )
    fi

    if [[ ! -f "${FENDD_BIN}" ]]; then
        cat >&2 <<EOF
error fendd not found at:
      ${FENDD_BIN}

Build it first:
      rustup target add ${RUST_TARGET}
      cd fendd && cargo build --release --target ${RUST_TARGET} --bin fendd

Or rerun with:
      FEND_BUILD_FENDD=1 scripts/prepare-linux-x86_64-runtime.sh
EOF
        exit 1
    fi

    local fendd_type
    fendd_type="$(file "${FENDD_BIN}" 2>/dev/null || true)"
    if ! grep -qi 'ELF 64-bit.*x86-64' <<<"${fendd_type}"; then
        die "fendd is not an x86_64 ELF binary: ${fendd_type}"
    fi

    detail "fendd" "found ($(du -h "${FENDD_BIN}" | cut -f1))"
}

download_claude() {
    if [[ "${FEND_SKIP_CLAUDE:-0}" == "1" ]]; then
        detail "claude" "skipped"
        return
    fi

    if [[ -f "${CLAUDE_DIR}/claude" ]]; then
        detail "claude" "already exists ($(du -h "${CLAUDE_DIR}/claude" | cut -f1))"
        return
    fi

    local dist version
    dist="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

    info "downloading optional Claude Code linux-x64 binary"
    version="$(curl -fsSL "${dist}/latest" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -z "${version}" ]]; then
        detail "claude" "latest version unavailable, skipped"
        return
    fi

    mkdir -p "${CLAUDE_DIR}"
    if curl -fL "${dist}/${version}/linux-x64/claude" -o "${CLAUDE_DIR}/claude" 2>/dev/null; then
        chmod +x "${CLAUDE_DIR}/claude"
        detail "claude" "installed ${version} ($(du -h "${CLAUDE_DIR}/claude" | cut -f1))"
    else
        rm -f "${CLAUDE_DIR}/claude"
        detail "claude" "download failed, skipped"
    fi
}

ensure_docker() {
    require_cmd docker
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running"
    fi
}

check_prerequisites() {
    local failed=0

    check_cmd() {
        if command -v "$1" >/dev/null 2>&1; then
            detail "$1" "ok"
        else
            detail "$1" "missing"
            failed=1
        fi
    }

    check_cmd curl
    check_cmd file
    check_cmd strings
    check_cmd docker

    if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
        detail "sha256" "ok"
    else
        detail "sha256" "missing sha256sum or shasum"
        failed=1
    fi

    if command -v docker >/dev/null 2>&1; then
        if docker info >/dev/null 2>&1; then
            detail "docker" "daemon ok"
        else
            detail "docker" "daemon unavailable"
            failed=1
        fi
    fi

    if [[ -f "${FENDD_BIN}" ]]; then
        local fendd_type
        fendd_type="$(file "${FENDD_BIN}" 2>/dev/null || true)"
        if grep -qi 'ELF 64-bit.*x86-64' <<<"${fendd_type}"; then
            detail "fendd" "${FENDD_BIN}"
        else
            detail "fendd" "wrong architecture: ${fendd_type}"
            failed=1
        fi
    elif [[ "${FEND_BUILD_FENDD:-0}" == "1" && -d "${PROJECT_ROOT}/fendd" ]]; then
        check_cmd cargo
        detail "fendd" "will build ${RUST_TARGET}"
    else
        detail "fendd" "missing: ${FENDD_BIN}"
        failed=1
    fi

    if [[ "${failed}" -ne 0 ]]; then
        die "linux-x86_64 runtime prerequisites failed"
    fi
}

build_rootfs() {
    if [[ -f "${ROOTFS_PATH}" && "${FEND_REBUILD_ROOTFS:-0}" != "1" ]]; then
        detail "rootfs" "already exists ($(du -h "${ROOTFS_PATH}" | cut -f1))"
        detail "rootfs" "set FEND_REBUILD_ROOTFS=1 to rebuild"
        return
    fi

    ensure_docker

    local kernel_version rootfs_build rootfs_tar tar_size_mb img_size_mb
    kernel_version="$(detect_kernel_version)"
    if [[ -n "${kernel_version}" ]]; then
        detail "kernel" "detected ${kernel_version}"
    else
        detail "kernel" "version detection failed; rootfs will not apt-install matching modules"
    fi

    info "building Ubuntu 24.04 ${DOCKER_PLATFORM} rootfs image"

    rootfs_build="${WORK_DIR}/rootfs_build"
    rootfs_tar="${WORK_DIR}/rootfs.tar"
    rm -rf "${rootfs_build}" "${rootfs_tar}"
    mkdir -p "${rootfs_build}"

    cp "${FENDD_BIN}" "${rootfs_build}/fendd"

    cat > "${rootfs_build}/Dockerfile" <<'DOCKER_EOF'
FROM ubuntu:24.04 AS rootfs

ENV DEBIAN_FRONTEND=noninteractive
ARG KERNEL_VERSION

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    e2fsprogs \
    git \
    iproute2 \
    iputils-ping \
    isc-dhcp-client \
    kmod \
    netbase \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

RUN if [ -n "$KERNEL_VERSION" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends "linux-modules-${KERNEL_VERSION}" \
        || echo "warning: linux-modules-${KERNEL_VERSION} unavailable"; \
      rm -rf /var/lib/apt/lists/*; \
    fi

RUN if id -u 1000 >/dev/null 2>&1; then \
      existing="$(getent passwd 1000 | cut -d: -f1)"; \
      usermod -l user -d /home/user -m -s /bin/bash "$existing"; \
      groupmod -n user "$existing" 2>/dev/null || true; \
    else \
      useradd -m -u 1000 -s /bin/bash user; \
    fi

COPY fendd /usr/local/bin/fendd
RUN chmod +x /usr/local/bin/fendd

RUN mkdir -p /workspace /opt/tools /home/user/.npm /home/user/.local/bin \
    /proc /sys /dev /dev/pts /run /tmp \
    && chmod 1777 /tmp \
    && chown -R 1000:1000 /home/user

RUN printf '127.0.0.1 localhost fend\n::1 localhost ip6-localhost ip6-loopback\n' > /etc/hosts.fend

RUN printf '#!/bin/sh\ncase "$1" in\n  bound|renew)\n    ip addr add "$ip/$mask" dev "$interface" 2>/dev/null\n    [ -n "$router" ] && ip route add default via "$router" dev "$interface" 2>/dev/null\n    [ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf\n    ;;\nesac\n' > /bin/simple_dhcp.sh \
    && chmod +x /bin/simple_dhcp.sh

RUN [ -f /usr/bin/env ] || ln -sf /bin/env /usr/bin/env
DOCKER_EOF

    docker build \
        --platform "${DOCKER_PLATFORM}" \
        --build-arg "KERNEL_VERSION=${kernel_version}" \
        -t fend-linux-x86_64-rootfs-builder \
        "${rootfs_build}" 2>&1 | while IFS= read -r line; do
            printf '      rootfs    %s\n' "${line}"
        done

    info "exporting rootfs"
    local container_id
    container_id="$(docker create --platform "${DOCKER_PLATFORM}" fend-linux-x86_64-rootfs-builder /bin/true)"
    docker export "${container_id}" -o "${rootfs_tar}"
    docker rm "${container_id}" >/dev/null

    tar_size_mb="$(du -m "${rootfs_tar}" | cut -f1)"
    img_size_mb=$(( tar_size_mb + tar_size_mb / 5 ))
    if [[ "${img_size_mb}" -lt 1024 ]]; then
        img_size_mb=1024
    fi
    detail "rootfs" "tar=${tar_size_mb}MB image=${img_size_mb}MB"

    cat > "${rootfs_build}/Dockerfile.mkfs" <<'MKFS_EOF'
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs && rm -rf /var/lib/apt/lists/*
MKFS_EOF

    docker build \
        --platform "${DOCKER_PLATFORM}" \
        -t fend-linux-x86_64-mkfs \
        -f "${rootfs_build}/Dockerfile.mkfs" \
        "${rootfs_build}" 2>&1 | while IFS= read -r line; do
            printf '      mkfs      %s\n' "${line}"
        done

    info "creating ext4 rootfs.img"
    docker run --rm --platform "${DOCKER_PLATFORM}" \
        -v "${rootfs_tar}:/rootfs.tar:ro" \
        -v "${RUNTIME_DIR}:/output" \
        fend-linux-x86_64-mkfs /bin/bash -c "
            set -euo pipefail
            mkdir -p /rootfs_dir
            tar -xf /rootfs.tar -C /rootfs_dir
            rm -rf /rootfs_dir/.dockerenv /rootfs_dir/proc/* /rootfs_dir/sys/* /rootfs_dir/dev/*
            mkdir -p /rootfs_dir/proc /rootfs_dir/sys /rootfs_dir/dev /rootfs_dir/dev/pts /rootfs_dir/run /rootfs_dir/tmp
            chmod 1777 /rootfs_dir/tmp
            if [ -f /rootfs_dir/etc/hosts.fend ]; then
                cp /rootfs_dir/etc/hosts.fend /rootfs_dir/etc/hosts
                rm /rootfs_dir/etc/hosts.fend
            fi
            mke2fs -t ext4 -d /rootfs_dir -L fend-rootfs -m 1 -N 100000 /output/rootfs.img ${img_size_mb}M
        " 2>&1 | while IFS= read -r line; do
            printf '      rootfs    %s\n' "${line}"
        done

    rm -f "${rootfs_tar}"
    rm -rf "${rootfs_build}"
    docker rmi fend-linux-x86_64-rootfs-builder fend-linux-x86_64-mkfs >/dev/null 2>&1 || true

    if [[ ! -f "${ROOTFS_PATH}" ]]; then
        die "rootfs.img was not created"
    fi

    detail "rootfs" "built ($(du -h "${ROOTFS_PATH}" | cut -f1))"
}

write_metadata() {
    local kernel_sha initrd_sha rootfs_sha
    kernel_sha="$(sha256_file "${KERNEL_PATH}")"
    initrd_sha="$(sha256_file "${INITRD_PATH}")"
    rootfs_sha="$(sha256_file "${ROOTFS_PATH}")"

    cat > "${METADATA_PATH}" <<EOF
target=linux-x86_64
ubuntu_base=${UBUNTU_BASE}
kernel_file=${KERNEL_FILE}
kernel_sha256=${kernel_sha}
initrd_file=${INITRD_FILE}
initrd_sha256=${initrd_sha}
rootfs_sha256=${rootfs_sha}
rust_target=${RUST_TARGET}
built_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
}

require_cmd curl
require_cmd file
require_cmd strings

mkdir -p "${RUNTIME_DIR}" "${WORK_DIR}"

if [[ "${CHECK_ONLY}" == "1" ]]; then
    info "checking linux-x86_64 runtime prerequisites"
    detail "target" "${RUNTIME_DIR}"
    detail "workdir" "${WORK_DIR}"
    check_prerequisites
    info "linux-x86_64 runtime prerequisites ok"
    exit 0
fi

info "preparing linux-x86_64 runtime"
detail "target" "${RUNTIME_DIR}"

ensure_ubuntu_sums
download_ubuntu_artifact "${KERNEL_FILE}" "${KERNEL_PATH}" "kernel"
download_ubuntu_artifact "${INITRD_FILE}" "${INITRD_PATH}" "initrd"

kernel_type="$(file "${KERNEL_PATH}" 2>/dev/null || true)"
if ! grep -qi 'x86 boot executable\|bzImage' <<<"${kernel_type}"; then
    detail "kernel" "warning: unexpected file type: ${kernel_type}"
fi

ensure_fendd
download_claude
build_rootfs
write_metadata

rm -rf "${WORK_DIR}/SHA256SUMS"

info "linux-x86_64 runtime ready"
detail "kernel" "${KERNEL_PATH}"
detail "initrd" "${INITRD_PATH}"
detail "rootfs" "${ROOTFS_PATH}"
detail "metadata" "${METADATA_PATH}"
printf '\n'
printf 'Next:\n'
printf '  scripts/linux-qemu-spike.sh /path/to/project\n'
