#!/usr/bin/env bash
# Phase 1 Linux backend spike launcher.
#
# This does not replace the Swift macOS backend. It encodes the first QEMU/KVM
# launch shape so Linux runtime work can be tested directly on an x86_64 host.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
usage: scripts/linux-qemu-spike.sh [--check] [workspace]

Options:
  --check                Validate prerequisites and runtime artifacts without
                         starting virtiofsd or QEMU.

Environment:
  FEND_RUNTIME_DIR       Runtime dir containing vmlinuz, initrd, rootfs.img.
                         Default: ~/.fend/runtime/linux-x86_64
  FEND_VIRTIOFSD        Override virtiofsd binary path.
  FEND_DEV_DIR           Device dir for preflight checks. Default: /dev
  FEND_QEMU_CID          Guest vsock CID. Default: 42
  FEND_QEMU_CPUS         vCPU count. Default: 2
  FEND_QEMU_MEMORY_MB    Memory in MiB. Default: 2048
  FEND_QEMU_NETWORK      passt | user | off. Default: passt

After boot, run from another Linux terminal:
  cd fendd
  cargo run --features host-tools --bin fend-vsock-smoke -- --cid 42 -- /bin/echo ok

Build runtime artifacts first with:
  scripts/prepare-linux-x86_64-runtime.sh
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
esac

if [[ "$#" -gt 1 ]]; then
    echo "error: expected at most one workspace argument" >&2
    usage
    exit 1
fi

FEND_HOME="${FEND_HOME:-"${HOME}/.fend"}"
DEV_DIR="${FEND_DEV_DIR:-/dev}"
KVM_DEV="${DEV_DIR}/kvm"
VHOST_VSOCK_DEV="${DEV_DIR}/vhost-vsock"
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

resolve_virtiofsd() {
    local override="${FEND_VIRTIOFSD:-}"
    if [[ -n "${override}" ]]; then
        if [[ "${override}" == */* ]]; then
            [[ -x "${override}" ]] && printf '%s\n' "${override}" && return 0
        elif command -v "${override}" >/dev/null 2>&1; then
            command -v "${override}"
            return 0
        fi
        return 1
    fi

    if command -v virtiofsd >/dev/null 2>&1; then
        command -v virtiofsd
        return 0
    fi

    local candidate
    for candidate in /usr/lib/virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd; do
        if [[ -x "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

VIRTIOFSD_PATH="$(resolve_virtiofsd || true)"
VIRTIOFSD_MODE="direct"
if [[ "${VIRTIOFSD_PATH}" == */usr/lib/virtiofsd ]]; then
    VIRTIOFSD_MODE="rootless-unshare"
fi

preflight() {
    local failed=0

    check_ok() {
        printf '      %-16s %s\n' "$1" "$2"
    }

    check_fail() {
        printf '      %-16s %s\n' "$1" "$2" >&2
        failed=1
    }

    if [[ "$(uname -s)" == "Linux" ]]; then
        check_ok "host" "Linux"
    else
        check_fail "host" "must be Linux"
    fi

    if [[ "$(uname -m)" == "x86_64" ]]; then
        check_ok "arch" "x86_64"
    else
        check_fail "arch" "must be x86_64"
    fi

    for cmd in qemu-system-x86_64 base64; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            check_ok "${cmd}" "ok"
        else
            check_fail "${cmd}" "missing"
        fi
    done

    if [[ -n "${VIRTIOFSD_PATH}" ]]; then
        check_ok "virtiofsd" "${VIRTIOFSD_PATH}"
    else
        check_fail "virtiofsd" "missing"
    fi

    if [[ "${VIRTIOFSD_MODE}" == "rootless-unshare" ]]; then
        if command -v unshare >/dev/null 2>&1; then
            check_ok "unshare" "ok"
        else
            check_fail "unshare" "missing"
        fi
    fi

    case "${NETWORK}" in
        passt)
            if command -v passt >/dev/null 2>&1; then
                check_ok "passt" "ok"
            else
                check_fail "passt" "missing"
            fi
            ;;
        user|off)
            check_ok "network" "${NETWORK}"
            ;;
        *)
            check_fail "network" "must be passt, user, or off"
            ;;
    esac

    if [[ -e "${KVM_DEV}" ]]; then
        if [[ -r "${KVM_DEV}" && -w "${KVM_DEV}" ]]; then
            check_ok "kvm" "${KVM_DEV}"
        else
            check_fail "kvm" "permission denied: ${KVM_DEV} (add the user to the kvm group)"
        fi
    else
        check_fail "kvm" "missing: ${KVM_DEV} (enable virtualization and load KVM)"
    fi

    if [[ -e "${VHOST_VSOCK_DEV}" ]]; then
        check_ok "vhost-vsock" "${VHOST_VSOCK_DEV}"
    else
        check_fail "vhost-vsock" "missing: ${VHOST_VSOCK_DEV} (try: sudo modprobe vhost_vsock)"
    fi

    if [[ -d "${WORKSPACE}" ]]; then
        check_ok "workspace" "${WORKSPACE}"
    else
        check_fail "workspace" "missing directory: ${WORKSPACE}"
    fi

    for artifact in "${KERNEL_PATH}" "${INITRD_PATH}" "${ROOTFS_PATH}"; do
        if [[ -f "${artifact}" ]]; then
            check_ok "artifact" "${artifact}"
        else
            check_fail "artifact" "missing: ${artifact}"
        fi
    done

    [[ "${failed}" -eq 0 ]]
}

if [[ "${CHECK_ONLY}" == "1" ]]; then
    echo "info  checking linux qemu spike"
    if preflight; then
        echo "info  linux qemu spike prerequisites ok"
        exit 0
    fi
    echo "error linux qemu spike prerequisites failed" >&2
    exit 1
fi

if ! preflight >/dev/null; then
    echo "error linux qemu spike prerequisites failed; run scripts/linux-qemu-spike.sh --check" >&2
    exit 1
fi

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

start_virtiofsd() {
    local name="$1"
    local source="$2"
    local socket="$3"

    if [[ "${VIRTIOFSD_MODE}" == "rootless-unshare" ]]; then
        unshare -r --map-auto -- \
            "${VIRTIOFSD_PATH}" \
            --socket-path="${socket}" \
            --shared-dir "${source}" \
            --sandbox chroot \
            >"${LOG_DIR}/virtiofsd-${name}.log" 2>&1 &
    else
        "${VIRTIOFSD_PATH}" \
            --socket-path="${socket}" \
            --cache=auto \
            -o "source=${source}" \
            >"${LOG_DIR}/virtiofsd-${name}.log" 2>&1 &
    fi
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
        NET_ARGS=(-netdev "passt,id=net0" -device "virtio-net-pci,netdev=net0")
        ;;
    user)
        NET_ARGS=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0")
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
    -append "console=ttyS0 root=/dev/vda rootwait rw init=/usr/local/bin/fendd quiet fend.epoch=${EPOCH} fend.cwd=${GUEST_WORKSPACE_B64}" \
    -drive "file=${ROOTFS_PATH},if=virtio,format=raw,cache=writeback" \
    -snapshot \
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
