# Linux Backend Plan

Fend's Linux support should preserve the macOS product shape: one command, one
project VM, project directory mounted in, secrets outside the VM, network policy
controlled per command, and warm reuse for repeated commands.

The Linux implementation should be split into phases. Each phase should leave
the repo in a shippable or at least testable state.

## Current Status

As of 2026-05-08, the Linux QEMU/KVM spike has been validated on a real Arch
x86_64 host. The repo now proves:

- `fend-linux doctor` passes on Arch with distro-packaged `virtiofsd`.
- `fend setup` prepares the Linux runtime artifacts without requiring the
  repo-local shell builder path.
- `fend-linux launch` boots the guest with both `--network user` and
  `--network passt`.
- `fendd` binds vsock port `1024`, and both smoke clients execute commands in
  `/workspace`.
- VirtioFS workspace writes round-trip back to the host under Arch's rootless
  `virtiofsd` setup.
- Normal guest egress works with `--network passt`.
- Per-command `FEND_NETWORK_MODE=off` still blocks DNS/connectivity inside the
  child process.

The Linux path is still a spike, not a shipped product:

- The Rust Linux crate now exposes `fend`, `fend-linux`, and `fend-daemon`
  binaries. The top-level `fend <command>` path works on a real host, and the
  first-run runtime bootstrap lives in the Rust binary.
- The disposable path keeps long-running commands attached, forwards guest
  ports back to `127.0.0.1`, and has been validated on a real Next.js app with
  `fend npm run dev`.
- Warm VM reuse landed: `fend <command>` connects to (or auto-spawns) a
  host-side `fend-daemon` that boots one VM per project, reuses it across
  concurrent commands, and reaps idle VMs after a TTL. `fend status` and
  `fend stop` now go through the daemon as well.
- Runtime preparation still depends on Docker for the local rootfs build.
- Full stdin passthrough and warm-VM interactive polish are not done.
- Real release publishing, CI, and distro-facing setup docs are not done.
- Daemon path has unit-test coverage on macOS host only; real-KVM soak is the
  next validation step.

## Daemon Architecture

The Linux warm-VM path mirrors the macOS `FendDaemon` shape with Linux-native
plumbing:

- `fend-daemon` — separate binary at `linux/src/bin/fend-daemon.rs`. Owns a
  `VmPool` and a Unix domain socket listener. Auto-spawned by `fend` on first
  use via `setsid()` so it survives the CLI's process group.
- `linux/src/pool.rs` — `VmPool` keeps one `VmEntry` per canonical project
  path, allocates CIDs from `CID_BASE = 100`, holds the `RunningVm` handle,
  ref-counts active sessions, and reaps `Running` VMs whose idle time exceeds
  `DEFAULT_IDLE_TTL` (30 min). Insert-before-unlock prevents concurrent
  `EnsureVm` calls for the same project from double-booting.
- `linux/src/daemon.rs` — accept loop with thread-per-connection dispatch. On
  startup, sweeps orphan VM run directories left by a stale daemon. Installs
  `SIGTERM`/`SIGINT`/`SIGHUP` handlers via `libc::sigaction` that flip a static
  `SHUTDOWN_REQUESTED` flag; the listener polls it between accepts.
- `linux/src/ipc.rs` — framed-JSON protocol (4-byte BE length prefix,
  `PROTOCOL_VERSION = 1`, 1 MiB cap). `Request`: `EnsureVm`, `Stop`, `Status`,
  `Shutdown`. `Response`: `VmReady { cid, run_dir, booted }`, `Stopped`,
  `Status`, `ShuttingDown`, `Error`.
- `linux/src/client.rs` — CLI-side client. `Session` holds the daemon
  `UnixStream` open for the lifetime of the command; the daemon treats socket
  close (including CLI crash) as session-end and decrements the ref count. On
  `connect_or_spawn`, the CLI auto-spawns the daemon (resolved via
  `FEND_DAEMON_BINARY` → `current_exe` parent → `PATH`), with stdio redirected
  to `<state-dir>/daemon.log`, then polls the socket for up to 5 s.

Socket and state paths are resolved with the same fallback chain:
`$FEND_DAEMON_SOCKET` → `$XDG_RUNTIME_DIR/fend/daemon.sock` →
`$FEND_HOME/run/daemon.sock` → `~/.fend/run/daemon.sock` →
`/tmp/fend-{uid}/daemon.sock`.

Useful env vars:

- `FEND_NO_DAEMON=1` — bypass the daemon entirely; falls back to the
  disposable per-command boot path. Also implied when `fend stop` is invoked
  with `--run-dir` (legacy single-VM teardown).
- `FEND_DAEMON_SOCKET` — override the daemon socket path.
- `FEND_DAEMON_BINARY` — override the binary used for auto-spawn.

## Phase 0: Baseline Quality

Goal: keep the current macOS implementation stable while Linux work starts.

- Keep `swift test --package-path swift` passing.
- Keep guest protocol tests reliable under concurrent stdin/signal/window-size
  writes.
- Keep public docs honest about platform support: macOS is supported today;
  Linux is in development.

Exit criteria:

- Full Swift suite passes locally.
- Current npm wrapper still rejects unsupported platforms clearly.
- No Linux planning changes alter macOS behavior.

## Phase 1: Linux Backend Design Spike

Goal: prove the Linux VM shape before building packaging or polish.

Assumption for the first spike: use QEMU/KVM as the compatibility backend. It
is larger than a custom VMM, but it lets us prove the important product
questions quickly: KVM availability, VirtioFS workspace mount, vsock control,
rootless networking, port forwarding, and `fendd` reuse.

Target requirements:

- x86_64 Linux host.
- `/dev/kvm` exists and is accessible by the user.
- Intel VT-x or AMD-V enabled in firmware.
- Kernel 5.10+ recommended.
- QEMU with KVM, virtiofs, virtio-vsock, and virtio-net support.
- `virtiofsd` for project/cache/tool mounts.
- `passt` for rootless user networking, unless the distro path forces a
  different first implementation.

Exit criteria:

- A documented manual QEMU command boots the Fend kernel/initrd/rootfs on Linux.
- The guest starts `fendd`.
- Host can connect to `fendd` over vsock.
- `fendd` can run a simple command in `/workspace`.
- `--network off` still isolates the child process network namespace.

Phase 1 spike artifacts now live in the repo:

- `scripts/prepare-linux-x86_64-runtime.sh` builds the Linux spike runtime
  artifacts in `~/.fend/runtime/linux-x86_64` by downloading Ubuntu 24.04 amd64
  cloud kernel/initrd files, verifying them against Ubuntu's SHA256SUMS, and
  building an Ubuntu 24.04 ext4 rootfs with an
  `x86_64-unknown-linux-musl` `fendd`.
- `scripts/linux-qemu-spike.sh` validates the Linux host prerequisites and
  launches the expected QEMU/KVM shape: direct kernel boot, virtio block
  rootfs, three VirtioFS shares (`workspace`, `cache`, `tools`), virtio-vsock,
  disposable rootfs writes, and rootless networking through `passt` by default.
- `fend-linux smoke` is the Linux host smoke client for the existing `fendd`
  frame protocol. It connects over virtio-vsock, waits for the daemon `Ready`
  frame, sends an `ExecuteCommand`, prints the captured stdout/stderr, and
  fails if the guest command exits non-zero. It retries the initial vsock
  connection for up to 30 seconds by default, which makes it safe to run while
  the guest is still booting. The same timeout also bounds the command session,
  and captured stdout/stderr are capped so a broken guest cannot hang the host
  CLI indefinitely or grow host memory without limit. The older
  `fendd/src/bin/fend-vsock-smoke.rs` helper remains available as a low-level
  protocol reference.
- `scripts/test-linux-spike-scripts.sh` runs host-independent shell checks with
  mocked Linux/KVM tools. It validates argument parsing, preflight checks,
  runtime artifact detection, and failure messages without booting QEMU.
- `linux/` is the separate Rust host-side implementation area for Linux. The
  first modules build the pure QEMU/KVM command model and Linux doctor/preflight
  report without launching QEMU. It also includes a small `fend-linux` spike
  binary so the Rust path can render Linux doctor output, inspect the launch
  plan, and supervise the first QEMU launch path before it grows into the full
  Linux host runner. The launch path now runs its own preflight before starting
  sidecars or QEMU; it checks only launch-time requirements, so Docker remains
  a runtime-bootstrap concern, `passt` is required only for explicit
  `--network passt`, and the default run path falls back to QEMU `user`
  networking when `passt` is unavailable.

Runtime image architecture is now split by script. Tool download resolution is
platform-aware, but the existing `swift/scripts/prepare-runtime.sh` still
builds the macOS arm64 runtime: Ubuntu arm64 kernel, Alpine aarch64 initrd
pieces, linux-arm64 Claude tooling, and an `aarch64-unknown-linux-musl`
`fendd`. The Linux x86_64 spike builder writes a separate runtime directory,
expected by the QEMU launcher at `~/.fend/runtime/linux-x86_64/`, containing:

- `vmlinuz`: x86_64 Linux kernel with virtio block, virtio-net, virtio-vsock,
  fuse, and virtiofs support available either built in or via the initrd.
- `initrd`: Ubuntu's matching amd64 cloud initrd. For the first spike this is
  deliberately less minimal than the macOS initrd, because it carries matching
  module dependencies and reduces boot-proving risk.
- `rootfs.img`: x86_64 ext4 image containing the static `fendd` binary and the
  same minimal userspace packages used by the macOS guest.

Manual spike flow on an x86_64 Linux workstation:

```bash
rustup target add x86_64-unknown-linux-musl
cd fendd
cargo build --release --target x86_64-unknown-linux-musl --bin fendd
cd ..
scripts/prepare-linux-x86_64-runtime.sh
```

The builder currently uses Docker to assemble the ext4 rootfs. That is still a
temporary Linux prerequisite until published runtime bundles exist, but the
end-user entrypoint no longer depends on a repo-local shell script.

Host-independent checks that can run on macOS:

```bash
bash -n scripts/prepare-linux-x86_64-runtime.sh
bash -n scripts/linux-qemu-spike.sh
scripts/test-linux-spike-scripts.sh
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- plan /tmp/project
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- launch --help
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke --help
cargo test --manifest-path fendd/Cargo.toml
cargo test --manifest-path linux/Cargo.toml
swift test --package-path swift
```

On a Linux host, run no-boot preflight before launching QEMU:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- doctor
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- plan /path/to/project
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- setup --help
```

`fend-linux launch` also runs a launch-specific preflight automatically before
it creates `virtiofsd` sockets or starts QEMU. Use `--network user` or
`--network off` when validating hosts without `passt`. The Rust supervisor
requires the workspace share to exist, creates cache/tool share directories when
needed, and launches QEMU with snapshot disk writes so the reusable rootfs image
stays disposable across smoke runs.

For the current end-user path, you can let the Linux binary bootstrap the
runtime directly:

```bash
fend doctor
fend setup
fend npm install
```

Inspect and manage warm VMs through the daemon:

```bash
fend status                  # one-line-per-VM table: CID STATE SESSIONS IDLE PROJECT
fend stop                    # stop the VM for the current project
fend stop --project /path    # stop a specific project's VM
fend stop --all              # stop every warm VM
FEND_NO_DAEMON=1 fend npm test   # bypass daemon, use a disposable VM
```

If you want to launch the VM explicitly after the runtime exists in
`~/.fend/runtime/linux-x86_64` or a custom `FEND_RUNTIME_DIR`, use the Rust
Linux supervisor directly:

```bash
FEND_RUNTIME_DIR="$HOME/.fend/runtime/linux-x86_64" \
  cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- launch /path/to/project
```

`fend-linux launch` prints the exact run dir it chose. Use that run dir with
`fend-linux stop` from another terminal when you want to tear the stack down
without hunting PIDs manually:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- stop \
  --run-dir /tmp/fend-linux-debug
```

The shell spike remains useful as a readable reference and fallback while the
Rust Linux host runner is built out:

```bash
scripts/prepare-linux-x86_64-runtime.sh --check
scripts/linux-qemu-spike.sh --check /path/to/project
```

To launch with the shell spike instead:

```bash
FEND_RUNTIME_DIR="$HOME/.fend/runtime/linux-x86_64" \
  scripts/linux-qemu-spike.sh /path/to/project
```

Then, from another terminal, verify the vsock command path:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke --cid 42 --timeout 60
```

Verify command-level network isolation:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke \
  --cid 42 --timeout 60 --env FEND_NETWORK_MODE=off -- /usr/bin/curl -I https://example.com
```

The expected result for the second command is a DNS/connectivity failure from
inside the sandboxed child process, while the VM itself may still have network
for package-manager and daemon needs.

`curl` is the preferred guest networking smoke check. `ping` is not reliable
for this path because guest commands run unprivileged and raw ICMP sockets are
expected to fail without additional capabilities.

## Linux MVP Checklist

The spike answered "can Fend work on Linux?" with yes. The remaining work is
turning the spike into the first Linux product path.

### P0: Productize The Current Spike

- [x] Expand the disposable Linux `fend <command>` path beyond one-shot runs:
  reuse VMs across commands, recover stale state, and stop depending on a
  per-command boot. (`fend-daemon` + `VmPool`; auto-spawn from CLI; orphan
  run-dir sweep on startup.)
- [x] Add Linux VM lifecycle management: one VM per project, reuse across
  commands, deterministic shutdown, stale-CID recovery, and orphan sidecar
  cleanup. (Idle reaper, ref-counted sessions via Unix-socket keepalive,
  `fend stop`/`fend status` route through the daemon.)
- [ ] Finish interactive command parity: stdin passthrough/prompt handling,
  long-running session polish, and any remaining TTY edge cases after the new
  attached session path.
- [ ] Extend the new localhost port forwarding beyond smoke validation with
  longer soak coverage and network event reporting on the Rust Linux path.
- [ ] Soak the current workspace/cache/tools mount model with real Node
  workflows on Arch and Ubuntu — including the new daemon path.

### P1: Remove Developer-Only Setup Friction

- Replace the current Docker-based runtime builder with an end-user runtime
  install flow.
- Decide what ships versus what stays distro-provided: QEMU, `virtiofsd`,
  `passt`, kernel/initrd/rootfs, and tool bundles.
- Turn the now-scripted Linux npm packaging path into a real release path:
  publish `@fendsh/cli-linux-x64`, add CI for `pack-npm` / local install
  verification, and document release order/platform support.
- Expand `doctor` so it covers the real end-user setup path and not only the
  spike prerequisites.

### P2: Match macOS Behavior Where It Matters

- Preserve the same command policy surface as macOS: network on/off, audit
  flows, tool mounts, shell hook behavior, and consistent logs.
- Confirm package-manager workflows end-to-end: `npm install`, `pnpm install`,
  `bun install`, test commands, and dev servers with forwarded ports.
- Harden ownership semantics for workspace, cache, and tools so user-visible
  behavior is stable across rootless/share configurations.
- Add Linux soak coverage in CI or dedicated host runners for Arch and Ubuntu.

### Linux MVP Exit Criteria

- `fend node -v` works from the top-level CLI on Linux x86_64.
- `fend npm install` and `fend npm run dev` work on real projects without
  manual runtime-prep steps beyond documented host prerequisites.
- Port forwarding, network isolation, and signal handling behave the same way a
  user would expect from the macOS product.
- `fend doctor` gives actionable setup output on Arch and Ubuntu.
- The Linux path is covered by repeatable end-to-end tests on real KVM hosts.

## Phase 2: Backend Boundary

Goal: separate host orchestration from macOS Virtualization.framework specifics.

Proposed boundary:

- `VMBackend`: start, stop, pause/resume if available, connect vsock, status.
- `DarwinVirtualizationBackend`: wraps the existing `VMInstance` behavior.
- `LinuxQemuBackend`: implemented separately in Rust under `linux/`; launches
  and supervises QEMU/KVM.
- Shared code remains responsible for config, audit, env filtering, terminal IO,
  protocol framing, and command policy.

Exit criteria:

- macOS code still uses Apple Virtualization.framework.
- Linux-specific code is isolated behind build/platform checks.
- Unit tests cover backend selection and command policy without booting a VM.

## Phase 3: Linux MVP

Goal: `fend <command>` works on a Linux workstation for common Node workflows.

Scope:

- Boot or reuse one VM per project.
- Mount workspace, npm cache, and tools.
- Run `node`, `npm`, `pnpm`, `bun`, and shell commands through `fendd`.
- Support network on/off.
- Stream stdout/stderr and forward signals.
- Apply Linux watch policy: `auto` uses polling for likely dev-server commands.

Exit criteria:

- `fend node -v` works on Linux x86_64.
- `fend npm install` writes `node_modules` to the host project through VirtioFS.
- `fend --network off node -e ...` fails outbound DNS/connectivity.
- `fend npm run dev` exposes the dev server on localhost.
- Basic docs cover Arch setup first.

## Phase 4: Linux Product Polish

Goal: make Linux feel close to the macOS experience.

- Add `fend doctor` Linux checks for `/dev/kvm`, group permissions, QEMU,
  `virtiofsd`, `passt`, kernel version, and nested virtualization.
- Improve terminal errors for missing KVM, denied `/dev/kvm`, missing
  `virtiofsd`, and missing `passt`.
- Add npm platform package target `linux-x64`.
- Add CI build jobs for Linux binaries.
- Add soak tests on Arch and Ubuntu.

Exit criteria:

- Fresh Arch user has a short setup path.
- Missing prerequisites produce actionable `doctor` output.
- Linux binary can be distributed through npm optional dependencies.

Direction change: Linux backend work stays separate from the Swift macOS host
implementation. New Linux host orchestration code lives under `linux/` in Rust;
Swift remains the macOS CLI/daemon implementation unless there is a small
cross-platform surface worth sharing deliberately. Linux doctor/preflight checks
now live in `fend_linux::doctor` and cover x86_64, QEMU, `virtiofsd`, `passt`,
Docker, Rust musl target, `/dev/kvm`, `/dev/vhost-vsock`, CPU virtualization
flags, and Linux runtime artifacts.

First real Arch hardware testing initially exposed an Arch-specific
`virtiofsd` resolution gap: the package installs `/usr/lib/virtiofsd`, while
the early spike only searched `PATH`. That issue, the related rootless
`virtiofsd` launch handling, the guest-side vsock module loading, the rootless
workspace ownership fix, and the `passt` NIC-name assumption are now resolved.
[`docs/linux-arch-debug-handover.md`](./linux-arch-debug-handover.md) remains
as a historical handover and debugging record.

## Phase 5: Mirror Watch Mode

Goal: replace Linux polling for long-running dev servers where polling overhead
is too high.

Design:

- Host project remains the source of truth.
- Fend mirrors source files into a guest-local ext4 workspace.
- Dev server runs from the guest-local workspace.
- Guest outputs are disposable by default.
- Default ignores include `.git`, `node_modules`, package-manager caches,
  `.next`, `dist`, `build`, and other generated directories.

Exit criteria:

- HMR works without polling for Vite/Next/Webpack-style projects.
- Guest-generated files do not overwrite host source unless explicitly allowed.
- Deletes and renames are handled deterministically.

## Open Decisions

- Whether the Linux CLI remains Swift long term or moves to Rust. The fastest
  path is to keep shared Swift CLI logic while the QEMU backend is proven; the
  long-term packaging and dependency story may still favor Rust.
- Whether to bundle QEMU/virtiofsd/passt or rely on distro packages. For the
  first Linux MVP, distro packages are simpler. For supply-chain control,
  bundling pinned builds may be better later.
- Whether a custom `rust-vmm` backend is worth the engineering cost after the
  QEMU/KVM MVP proves the product path.

## References

- QEMU network backends, including `passt`:
  <https://www.qemu.org/docs/master/system/devices/net.html>
- QEMU/virtiofsd command shape:
  <https://virtio-fs.gitlab.io/qemu/tools/virtiofsd.html>
- Ubuntu 24.04 cloud kernel/initrd index:
  <https://cloud-images.ubuntu.com/releases/noble/release/unpacked/>
