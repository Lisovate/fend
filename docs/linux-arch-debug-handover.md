# Linux Arch Debug Handover

This handover captures the first real Arch Linux test run for the Linux
QEMU/KVM spike. It is written for a Linux-side Codex CLI session so debugging
can continue directly on the target machine.

## Context

- Repo: `https://github.com/Lisovate/fend.git`
- Tested commit: `f2cc2da fix: harden linux qemu smoke path`
- Target host: Arch Linux, x86_64, local machine
- Linux implementation area: `linux/`
- Guest daemon/runtime area: `fendd/` and `scripts/prepare-linux-x86_64-runtime.sh`
- Current Linux flow is still a spike. The npm `fend` wrapper is not the Linux
  entry point yet; use `cargo run --manifest-path linux/Cargo.toml --bin
  fend-linux -- ...`.

The captured terminal output was saved outside the repo as
`/Users/pawel/Downloads/fendTestingOutput.txt` on the macOS machine. This file
is not expected to exist on the Linux host, so this document includes the
important findings.

## What Worked

The local Rust and script checks passed on Arch:

```bash
cargo test --manifest-path linux/Cargo.toml
cargo test --manifest-path fendd/Cargo.toml
scripts/test-linux-spike-scripts.sh
```

Results from the captured output:

- `linux/` tests: 38 passed.
- `fendd/` tests: 26 passed.
- Host-independent Linux spike script tests passed.
- `/dev/kvm` was accessible.
- `/dev/vhost-vsock` existed and was accessible.
- CPU virtualization flags were available.
- Docker was available.
- `passt` was available.
- `rustup target add x86_64-unknown-linux-musl` had been done.
- Runtime artifact build completed:
  - `~/.fend/runtime/linux-x86_64/vmlinuz`
  - `~/.fend/runtime/linux-x86_64/initrd`
  - `~/.fend/runtime/linux-x86_64/rootfs.img`
  - `~/.fend/runtime/linux-x86_64/metadata.env`

The runtime builder downloaded Ubuntu 24.04 amd64 cloud kernel/initrd files,
built a musl `fendd`, created a Docker-built Ubuntu rootfs, installed matching
kernel modules, and wrote a 249 MB `rootfs.img`.

## What Failed

`fend-linux doctor`, `scripts/linux-qemu-spike.sh --check`, and
`fend-linux launch` all reported:

```text
virtiofsd         missing
issues
  - Install virtiofsd.
```

But Arch had the package installed:

```bash
sudo pacman -S virtiofsd
# warning: virtiofsd-1.13.3-1 is up to date
```

This strongly indicates a repo bug, not a host setup problem.

Arch installs the binary at:

```text
/usr/lib/virtiofsd
```

The current code and script only search for `virtiofsd` in `PATH`:

- `linux/src/doctor.rs` uses `command_exists("virtiofsd")`.
- `linux/src/qemu.rs` has `SharePlan::virtiofsd_program() -> "virtiofsd"`.
- `scripts/linux-qemu-spike.sh` checks `command -v virtiofsd`.
- `scripts/linux-qemu-spike.sh` launches `virtiofsd` by bare command name.

References:

- Arch package file list shows `usr/lib/virtiofsd`:
  <https://archlinux.org/packages/extra/x86_64/virtiofsd/files/>
- ArchWiki shows rootless launch through `/usr/lib/virtiofsd`:
  <https://wiki.archlinux.org/title/Qemu#Host_file_sharing_with_virtiofsd>
- QEMU virtiofsd docs describe `-o source=PATH` and the vhost-user fs shape:
  <https://virtio-fs.gitlab.io/qemu/tools/virtiofsd.html>

## Ignore These Until Launch Works

The later `fend-linux smoke` failures are expected because no VM successfully
started:

```text
error: timed out connecting to fendd on vsock cid 42 port 1024 after 60s:
No such device (os error 19)
```

Do not debug `smoke` first. It depends on `fend-linux launch` getting past
preflight, starting three `virtiofsd` sidecars, starting QEMU, booting the
guest, and `fendd` binding vsock port `1024`.

## Immediate Linux Workaround

To unblock validation without changing code, make `virtiofsd` visible in
`PATH` for the current shell:

```bash
mkdir -p "$HOME/.local/bin"
ln -sf /usr/lib/virtiofsd "$HOME/.local/bin/virtiofsd"
export PATH="$HOME/.local/bin:$PATH"

command -v virtiofsd
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- doctor
scripts/linux-qemu-spike.sh --check "$PWD"
```

If `doctor` and `--check` pass after this, continue with an explicit run dir so
the next failure leaves logs:

```bash
mkdir -p ~/tmp/fend-linux-smoke
rm -rf /tmp/fend-linux-debug

FEND_RUN_DIR=/tmp/fend-linux-debug \
  cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- launch \
  ~/tmp/fend-linux-smoke
```

From another terminal, only after the launch terminal shows `fendd: ready` or
`fendd: listening on vsock port 1024`:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke \
  --cid 42 --timeout 60
```

If launch fails before QEMU starts, inspect:

```bash
find /tmp/fend-linux-debug -maxdepth 3 -type f -print
sed -n '1,200p' /tmp/fend-linux-debug/logs/virtiofsd-workspace.log
sed -n '1,200p' /tmp/fend-linux-debug/logs/virtiofsd-cache.log
sed -n '1,200p' /tmp/fend-linux-debug/logs/virtiofsd-tools.log
```

## Likely Next Failure

After the binary path is fixed, Arch may still fail because the current
supervisor starts `virtiofsd` directly as the regular user:

```bash
virtiofsd --socket-path=... --cache=auto -o source=...
```

ArchWiki recommends rootless `virtiofsd` through a user namespace:

```bash
unshare -r --map-auto -- /usr/lib/virtiofsd \
  --socket-path=/tmp/vm-share.sock \
  --shared-dir /tmp/vm-share \
  --sandbox chroot
```

The QEMU docs still document the older `-o source=PATH` form, but the Rust
`virtiofsd` packaging on Arch commonly uses `--shared-dir`. The Linux-side
Codex session should test the local binary directly:

```bash
rm -f /tmp/fend-vfs-test.sock
mkdir -p /tmp/fend-vfs-share

/usr/lib/virtiofsd --help | sed -n '1,120p'
unshare -r --map-auto -- /usr/lib/virtiofsd \
  --socket-path=/tmp/fend-vfs-test.sock \
  --shared-dir /tmp/fend-vfs-share \
  --sandbox chroot
```

Run that in one terminal, then in another:

```bash
ls -l /tmp/fend-vfs-test.sock
```

If `unshare --map-auto` fails, check subordinate uid/gid mappings:

```bash
grep "^$USER:" /etc/subuid /etc/subgid
```

If missing, add mappings and log in again:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
```

## Code Changes To Make

Keep Linux code separate from Swift/macOS unless the change is docs-only.

### 1. Resolve `virtiofsd` By Path

Add a Linux tool resolver, probably under `linux/src/doctor.rs` or a new
`linux/src/tools.rs`.

Resolution order:

1. `FEND_VIRTIOFSD` if set.
2. `PATH` lookup for `virtiofsd`.
3. Known distro paths:
   - `/usr/lib/virtiofsd` on Arch.
   - `/usr/libexec/virtiofsd` on some distros.
   - `/usr/lib/qemu/virtiofsd` for older QEMU packaging.

Doctor output should show the resolved path, not only `available`:

```text
virtiofsd         /usr/lib/virtiofsd
```

If the package is installed in a known path, doctor must not report
`Install virtiofsd`.

### 2. Pass The Resolved Path Into Launch

`SharePlan` currently hardcodes the program:

```rust
pub fn virtiofsd_program(&self) -> &'static str {
    "virtiofsd"
}
```

Change the launch model so the program is data:

- Add `virtiofsd_program: PathBuf` to `LaunchConfig`.
- Add `virtiofsd_program: PathBuf` to `SharePlan`, or put it on `LaunchPlan`.
- Build `ProcessSpec.program` from the resolved path.
- Keep tests using a fake path or `virtiofsd` string.

### 3. Support Rootless Arch Invocation

Decide whether to normalize to the Rust `virtiofsd` CLI:

```bash
unshare -r --map-auto -- /usr/lib/virtiofsd \
  --socket-path=SOCKET \
  --shared-dir SOURCE \
  --sandbox chroot
```

This likely means `ProcessSpec` needs to support a wrapper command:

```text
program = "unshare"
args = [
  "-r", "--map-auto", "--",
  "/usr/lib/virtiofsd",
  "--socket-path=...",
  "--shared-dir", "...",
  "--sandbox", "chroot",
]
```

Do not require users to run `fend-linux` as root for the normal MVP path.

Doctor/preflight should check:

- `unshare` is available when rootless `virtiofsd` is selected.
- `/etc/subuid` and `/etc/subgid` contain entries for the current user, or
  output an actionable message.

### 4. Update The Shell Spike Too

The shell spike is still useful as a readable fallback, so update
`scripts/linux-qemu-spike.sh` in parallel:

- Honor `FEND_VIRTIOFSD`.
- Check known distro paths.
- Launch the resolved path.
- Prefer rootless `unshare` form on Arch if direct regular-user launch fails.

Update `scripts/test-linux-spike-scripts.sh` with a mocked
`/usr/lib/virtiofsd`-style case.

### 5. Improve Launch Diagnostics

The current Rust `launch` command runs QEMU with inherited stdio, but it does
not print the run dir/log dir before starting sidecars. Add a short launch
summary before sidecars start:

```text
fend linux launch
  workspace  /home/pawel/tmp/fend-linux-smoke
  runtime    /home/pawel/.fend/runtime/linux-x86_64
  run dir    /tmp/fend-linux-debug
  logs       /tmp/fend-linux-debug/logs
  cid        42
  network    passt
```

When a `virtiofsd` child exits before its socket is ready, include the first
screenful of that share's log in the error output, or at least print the exact
log path.

### 6. Then Debug Boot

Once `virtiofsd` sidecars start and QEMU launches, expected guest messages are:

```text
fendd: starting
fendd: mounted /proc (proc)
fendd: mounted /sys (sysfs)
fendd: mounted /dev (devtmpfs)
fendd: mounted /workspace (virtiofs)
fendd: listening on vsock port 1024
fendd: ready
```

If QEMU exits before these messages, capture:

```bash
FEND_RUN_DIR=/tmp/fend-linux-debug \
  cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- launch \
  --network user \
  ~/tmp/fend-linux-smoke
```

Also render the exact command:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- plan \
  --network user \
  --run-dir /tmp/fend-linux-debug \
  ~/tmp/fend-linux-smoke
```

## Verification Checklist After Fixes

Run the standard checks:

```bash
cargo test --manifest-path linux/Cargo.toml
cargo test --manifest-path fendd/Cargo.toml
scripts/test-linux-spike-scripts.sh
cargo fmt --manifest-path linux/Cargo.toml --check
cargo clippy --manifest-path linux/Cargo.toml --all-targets -- -D warnings
```

Then run real Arch validation:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- doctor
scripts/linux-qemu-spike.sh --check "$PWD"

mkdir -p ~/tmp/fend-linux-smoke
rm -rf /tmp/fend-linux-debug

FEND_RUN_DIR=/tmp/fend-linux-debug \
  cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- launch \
  ~/tmp/fend-linux-smoke
```

From another terminal:

```bash
cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke \
  --cid 42 --timeout 60

cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke \
  --cid 42 --timeout 60 \
  -- /bin/sh -lc 'echo guest-write > /workspace/from-guest.txt'

cat ~/tmp/fend-linux-smoke/from-guest.txt

cargo run --manifest-path linux/Cargo.toml --bin fend-linux -- smoke \
  --cid 42 --timeout 60 \
  --env FEND_NETWORK_MODE=off \
  -- /usr/bin/curl -I https://example.com
```

Expected:

- `doctor` passes.
- QEMU boots and leaves `fendd` running.
- `smoke` prints `fend-linux-ok`.
- `/workspace` writes appear on the host.
- `FEND_NETWORK_MODE=off` makes curl fail inside the sandboxed command.
- Stopping launch cleans up QEMU and `virtiofsd` sidecars.

## Product Notes From This Test

This test exposed two product-quality issues before the VM even booted:

- Distro packaging variance matters. We cannot assume host tools are in
  `PATH`, especially for low-level virtualization tools.
- Linux diagnostics need to be much more concrete than generic "install X".
  If a package is installed but the binary lives in a distro-specific path,
  `doctor` should explain that and either use it automatically or show the
  exact override.

For the Linux MVP, prioritize boring, inspectable behavior over hiding all the
details. A good first Linux experience is:

1. `fend-linux doctor` finds installed distro tools.
2. Missing prerequisites include exact Arch commands.
3. Launch prints run/log paths.
4. Sidecar failures point to the exact log.
5. Smoke failures explain whether the VM is absent, booting, or reachable but
   not speaking the protocol.
