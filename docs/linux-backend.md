# Linux Backend Plan

Fend's Linux support should preserve the macOS product shape: one command, one
project VM, project directory mounted in, secrets outside the VM, network policy
controlled per command, and warm reuse for repeated commands.

The Linux implementation should be split into phases. Each phase should leave
the repo in a shippable or at least testable state.

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

- `scripts/linux-qemu-spike.sh` validates the Linux host prerequisites and
  launches the expected QEMU/KVM shape: direct kernel boot, virtio block
  rootfs, three VirtioFS shares (`workspace`, `cache`, `tools`), virtio-vsock,
  and rootless networking through `passt` by default.
- `fendd/src/bin/fend-vsock-smoke.rs` is a gated Linux host smoke client for
  the existing fendd frame protocol. Build it with
  `cargo run --features host-tools --bin fend-vsock-smoke -- ...`.

The current blocker is runtime architecture, not the host command shape. The
existing `swift/scripts/prepare-runtime.sh` builds the macOS arm64 runtime:
Ubuntu arm64 kernel, Alpine aarch64 initrd pieces, linux-arm64 Node/Claude
tools, and an `aarch64-unknown-linux-musl` `fendd`. The Linux x86_64 backend
needs a separate runtime directory, expected by the spike script at
`~/.fend/runtime/linux-x86_64/`, containing:

- `vmlinuz`: x86_64 Linux kernel with virtio block, virtio-net, virtio-vsock,
  fuse, and virtiofs support available either built in or via the initrd.
- `initrd`: x86_64 initramfs that mounts `/dev/vda` and switch-roots into
  `/usr/local/bin/fendd`.
- `rootfs.img`: x86_64 ext4 image containing the static `fendd` binary and the
  same minimal userspace packages used by the macOS guest.

Manual spike flow on an x86_64 Linux workstation:

```bash
rustup target add x86_64-unknown-linux-musl
cd fendd
cargo build --release --target x86_64-unknown-linux-musl --bin fendd
```

After placing x86_64 `vmlinuz`, `initrd`, and `rootfs.img` in
`~/.fend/runtime/linux-x86_64` or setting `FEND_RUNTIME_DIR`, launch the VM:

```bash
FEND_RUNTIME_DIR="$HOME/.fend/runtime/linux-x86_64" \
  scripts/linux-qemu-spike.sh /path/to/project
```

Then, from another terminal, verify the vsock command path:

```bash
cd fendd
cargo run --features host-tools --bin fend-vsock-smoke -- \
  --cid 42 -- /bin/echo fend-linux-ok
```

Verify command-level network isolation:

```bash
cd fendd
cargo run --features host-tools --bin fend-vsock-smoke -- \
  --cid 42 --env FEND_NETWORK_MODE=off -- /usr/bin/curl -I https://example.com
```

The expected result for the second command is a DNS/connectivity failure from
inside the sandboxed child process, while the VM itself may still have network
for package-manager and daemon needs.

## Phase 2: Backend Boundary

Goal: separate host orchestration from macOS Virtualization.framework specifics.

Proposed boundary:

- `VMBackend`: start, stop, pause/resume if available, connect vsock, status.
- `DarwinVirtualizationBackend`: wraps the existing `VMInstance` behavior.
- `LinuxQemuBackend`: launches and supervises QEMU/KVM.
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
