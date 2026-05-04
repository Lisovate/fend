#!/usr/bin/env bash
# Phase 1 Linux backend spike launcher.
#
# This does not replace the Swift macOS backend. It encodes the first QEMU/KVM
# launch shape so Linux runtime work can be tested directly on an x86_64 host.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/linux-qemu-spike.sh [workspace]

Environment:
  FEND_RUNTIME_DIR       Runtime dir containing vmlinuz, initrd, rootfs.img.
                         Default: ~/.fend/runtime/linux-x86_64
  FEND_QEMU_CID          Guest vsock CID. Default: 42
  FEND_QEMU_CPUS         vCPU count. Default: 2
  FEND_QEMU_MEMORY_MB    Memory in MiB. Default: 2048
  FEND_QEMU_NETWORK      passt | user | off. Default: passt

After boot, run from another Linux terminal:
  cd fendd
  cargo run --features host-tools --bin fend-vsock-smoke -- --cid 42 -- /bin/echo ok
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "error: this spike must run on a Linux host with KVM" >&2
    exit 1
fi

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "error: this spike currently targets x86_64 Linux hosts only" >&2
    exit 1
fi

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing required command: $1" >&2
        exit 1
    fi
}

require_cmd qemu-system-x86_64
require_cmd virtiofsd

if [[ ! -e /dev/kvm ]]; then
    echo "error: /dev/kvm is missing; enable virtualization in firmware and load KVM" >&2
    exit 1
fi

if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "error: current user cannot access /dev/kvm; add the user to the distro's kvm group" >&2
    exit 1
fi

FEND_HOME="${FEND_HOME:-"${HOME}/.fend"}"
RUNTIME_DIR="${FEND_RUNTIME_DIR:-"${FEND_HOME}/runtime/linux-x86_64"}"
KERNEL_PATH="${FEND_KERNEL:-"${RUNTIME_DIR}/vmlinuz"}"
INITRD_PATH="${FEND_INITRD:-"${RUNTIME_DIR}/initrd"}"
ROOTFS_PATH="${FEND_ROOTFS:-"${RUNTIME_DIR}/rootfs.img"}"
WORKSPACE="${1:-"${PWD}"}"
CACHE_DIR="${FEND_CACHE_DIR:-"${FEND_HOME}/cache/npm"}"
TOOLS_DIR="${FEND_TOOLS_DIR:-"${FEND_HOME}/tools"}"
GUEST_CID="${FEND_QEMU_CID:-42}"
CPUS="${FEND_QEMU_CPUS:-2}"
MEMORY_MB="${FEND_QEMU_MEMORY_MB:-2048}"
NETWORK="${FEND_QEMU_NETWORK:-passt}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fend-qemu.XXXXXX")"
LOG_DIR="${RUN_DIR}/logs"
mkdir -p "${CACHE_DIR}" "${TOOLS_DIR}" "${LOG_DIR}"

VIRTIOFSD_PIDS=()
cleanup() {
    for pid in "${VIRTIOFSD_PIDS[@]:-}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    rm -rf "${RUN_DIR}"
}
trap cleanup EXIT INT TERM

for artifact in "${KERNEL_PATH}" "${INITRD_PATH}" "${ROOTFS_PATH}"; do
    if [[ ! -f "${artifact}" ]]; then
        cat >&2 <<EOF
error: missing runtime artifact: ${artifact}

Phase 1 expects x86_64 guest artifacts in:
  ${RUNTIME_DIR}

The current prepare-runtime.sh builds the macOS arm64 runtime. Build or place
linux-x86_64 vmlinuz, initrd, and rootfs.img there before launching QEMU.
EOF
        exit 1
    fi
done

if [[ "${NETWORK}" == "passt" ]]; then
    require_cmd passt
fi

start_virtiofsd() {
    local name="$1"
    local source="$2"
    local socket="$3"

    virtiofsd \
        --socket-path="${socket}" \
        --cache=auto \
        -o "source=${source}" \
        >"${LOG_DIR}/virtiofsd-${name}.log" 2>&1 &
    local pid="$!"
    VIRTIOFSD_PIDS+=("${pid}")

    for _ in $(seq 1 50); do
        if [[ -S "${socket}" ]]; then
            return 0
        fi
        if ! kill -0 "${pid}" >/dev/null 2>&1; then
            echo "error: virtiofsd failed for ${name}; see ${LOG_DIR}/virtiofsd-${name}.log" >&2
            exit 1
        fi
        sleep 0.1
    done

    echo "error: timed out waiting for virtiofsd socket: ${socket}" >&2
    exit 1
}

base64_one_line() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        printf '%s' "$1" | base64 -w0
    else
        printf '%s' "$1" | base64 | tr -d '\n'
    fi
}

WORKSPACE_SOCKET="${RUN_DIR}/workspace.sock"
CACHE_SOCKET="${RUN_DIR}/cache.sock"
TOOLS_SOCKET="${RUN_DIR}/tools.sock"
start_virtiofsd workspace "${WORKSPACE}" "${WORKSPACE_SOCKET}"
start_virtiofsd cache "${CACHE_DIR}" "${CACHE_SOCKET}"
start_virtiofsd tools "${TOOLS_DIR}" "${TOOLS_SOCKET}"

NET_ARGS=()
case "${NETWORK}" in
    passt)
        NET_ARGS=(-netdev passt,id=net0 -device virtio-net-pci,netdev=net0)
        ;;
    user)
        NET_ARGS=(-netdev user,id=net0 -device virtio-net-pci,netdev=net0)
        ;;
    off)
        ;;
    *)
        echo "error: FEND_QEMU_NETWORK must be passt, user, or off" >&2
        exit 1
        ;;
esac

EPOCH="$(date +%s)"
GUEST_WORKSPACE="/workspace"
GUEST_WORKSPACE_B64="$(base64_one_line "${GUEST_WORKSPACE}")"

echo "info  qemu spike"
echo "      workspace  ${WORKSPACE}"
echo "      runtime    ${RUNTIME_DIR}"
echo "      cid        ${GUEST_CID}"
echo "      network    ${NETWORK}"
echo "      logs       ${LOG_DIR}"
echo ""

qemu-system-x86_64 \
    -machine q35,accel=kvm \
    -cpu host \
    -smp "${CPUS}" \
    -m "${MEMORY_MB}" \
    -object "memory-backend-memfd,id=mem,size=${MEMORY_MB}M,share=on" \
    -numa node,memdev=mem \
    -kernel "${KERNEL_PATH}" \
    -initrd "${INITRD_PATH}" \
    -append "console=ttyS0 quiet fend.epoch=${EPOCH} fend.cwd=${GUEST_WORKSPACE_B64}" \
    -drive "file=${ROOTFS_PATH},if=virtio,format=raw,cache=writeback" \
    -device "vhost-vsock-pci,id=fend-vsock,guest-cid=${GUEST_CID}" \
    -chardev "socket,id=char-workspace,path=${WORKSPACE_SOCKET}" \
    -device "vhost-user-fs-pci,chardev=char-workspace,tag=workspace" \
    -chardev "socket,id=char-cache,path=${CACHE_SOCKET}" \
    -device "vhost-user-fs-pci,chardev=char-cache,tag=cache" \
    -chardev "socket,id=char-tools,path=${TOOLS_SOCKET}" \
    -device "vhost-user-fs-pci,chardev=char-tools,tag=tools" \
    "${NET_ARGS[@]}" \
    -nographic \
    -serial mon:stdio \
    -no-reboot
