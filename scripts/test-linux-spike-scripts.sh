#!/usr/bin/env bash
# Host-independent checks for the Linux runtime builder and QEMU spike scripts.
# This mocks a Linux x86_64/KVM host so the script control flow can be tested on
# macOS CI/dev machines. It does not boot QEMU.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fend-linux-script-tests.XXXXXX")"

cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

log() {
    printf 'ok    %s\n' "$*"
}

fail() {
    printf 'fail  %s\n' "$*" >&2
    exit 1
}

run_ok() {
    local name="$1"
    shift
    if "$@" >"${TMP_ROOT}/${name}.out" 2>"${TMP_ROOT}/${name}.err"; then
        log "${name}"
    else
        cat "${TMP_ROOT}/${name}.out" >&2 || true
        cat "${TMP_ROOT}/${name}.err" >&2 || true
        fail "${name}"
    fi
}

run_fail() {
    local name="$1"
    shift
    if "$@" >"${TMP_ROOT}/${name}.out" 2>"${TMP_ROOT}/${name}.err"; then
        cat "${TMP_ROOT}/${name}.out" >&2 || true
        fail "${name}: expected failure"
    fi
    log "${name}"
}

FAKEBIN="${TMP_ROOT}/fakebin"
mkdir -p "${FAKEBIN}"

cat > "${FAKEBIN}/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Linux\n' ;;
    -m) printf 'x86_64\n' ;;
    *) printf 'Linux\n' ;;
esac
EOF

cat > "${FAKEBIN}/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    info) exit 0 ;;
    *) printf 'fake docker: %s\n' "$*" >&2; exit 0 ;;
esac
EOF

cat > "${FAKEBIN}/file" <<'EOF'
#!/usr/bin/env bash
printf '%s: ELF 64-bit LSB executable, x86-64\n' "${1:-file}"
EOF

cat > "${FAKEBIN}/strings" <<'EOF'
#!/usr/bin/env bash
printf '6.8.0-100-generic\n'
EOF

for cmd in qemu-system-x86_64 virtiofsd passt cargo curl; do
    cat > "${FAKEBIN}/${cmd}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done

chmod +x "${FAKEBIN}"/*

RUNTIME_DIR="${TMP_ROOT}/runtime"
DEV_DIR="${TMP_ROOT}/dev"
WORKSPACE="${TMP_ROOT}/workspace"
FENDD_BIN="${TMP_ROOT}/fendd"

mkdir -p "${RUNTIME_DIR}" "${DEV_DIR}" "${WORKSPACE}" "${TMP_ROOT}/home" "${TMP_ROOT}/work"
touch "${RUNTIME_DIR}/vmlinuz" "${RUNTIME_DIR}/initrd" "${RUNTIME_DIR}/rootfs.img"
touch "${DEV_DIR}/kvm" "${DEV_DIR}/vhost-vsock" "${FENDD_BIN}"
chmod 600 "${DEV_DIR}/kvm" "${DEV_DIR}/vhost-vsock" "${FENDD_BIN}"

COMMON_ENV=(
    "PATH=${FAKEBIN}:${PATH}"
    "FEND_HOME=${TMP_ROOT}/home"
    "FEND_RUNTIME_DIR=${RUNTIME_DIR}"
    "FEND_WORK_DIR=${TMP_ROOT}/work"
)

run_ok "prepare-help" \
    "${PROJECT_ROOT}/scripts/prepare-linux-x86_64-runtime.sh" --help

run_ok "qemu-help" \
    "${PROJECT_ROOT}/scripts/linux-qemu-spike.sh" --help

run_ok "prepare-check" \
    env "${COMMON_ENV[@]}" "FENDD_BIN=${FENDD_BIN}" \
    "${PROJECT_ROOT}/scripts/prepare-linux-x86_64-runtime.sh" --check

run_ok "qemu-check" \
    env "${COMMON_ENV[@]}" "FEND_DEV_DIR=${DEV_DIR}" \
    "${PROJECT_ROOT}/scripts/linux-qemu-spike.sh" --check "${WORKSPACE}"

rm -f "${RUNTIME_DIR}/rootfs.img"
run_fail "qemu-check-missing-rootfs" \
    env "${COMMON_ENV[@]}" "FEND_DEV_DIR=${DEV_DIR}" \
    "${PROJECT_ROOT}/scripts/linux-qemu-spike.sh" --check "${WORKSPACE}"
grep -q "rootfs.img" "${TMP_ROOT}/qemu-check-missing-rootfs.err" \
    || fail "qemu-check-missing-rootfs: expected rootfs error"
touch "${RUNTIME_DIR}/rootfs.img"

run_fail "qemu-check-bad-network" \
    env "${COMMON_ENV[@]}" "FEND_DEV_DIR=${DEV_DIR}" "FEND_QEMU_NETWORK=bad" \
    "${PROJECT_ROOT}/scripts/linux-qemu-spike.sh" --check "${WORKSPACE}"
grep -q "must be passt, user, or off" "${TMP_ROOT}/qemu-check-bad-network.err" \
    || fail "qemu-check-bad-network: expected network error"

run_fail "prepare-check-missing-fendd" \
    env "${COMMON_ENV[@]}" "FENDD_BIN=${TMP_ROOT}/missing-fendd" \
    "${PROJECT_ROOT}/scripts/prepare-linux-x86_64-runtime.sh" --check
grep -q "missing" "${TMP_ROOT}/prepare-check-missing-fendd.out" \
    || fail "prepare-check-missing-fendd: expected missing fendd output"

log "linux spike script tests complete"
