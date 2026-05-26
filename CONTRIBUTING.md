# Contributing

Thanks for taking a look at Fend.

Fend is still alpha. The high-level architecture in
[ARCHITECTURE.md](./ARCHITECTURE.md) is real, but some parts are still being
explored. If you want to make a large architectural change, open an issue first
so we can discuss the direction before you spend time building it.

## Prerequisites

- macOS 14+ on Apple Silicon for the primary host path
- Xcode 15+ for the Swift CLI and daemon
- Rust stable
- Rust target: `aarch64-unknown-linux-musl`
- Docker — **contributors only**, for building the guest rootfs image
  locally via `fend setup --build-from-source`. End users never need
  Docker; they get a prebuilt runtime bundle from GitHub Releases.

Install the Rust target with:

```bash
rustup target add aarch64-unknown-linux-musl
```

## Building the guest runtime locally

The release pipeline publishes a `fend-runtime-darwin-arm64-v<VERSION>.tar.zst`
asset to GitHub Releases for every tag, and the notarized `fend` binary
auto-fetches + SHA-verifies that asset on first run. When you're working
from a `swift run`/`swift build` source tree the binary is unsigned and
its baked SHA is the empty-string `dev` placeholder, so the prebuilt
path is intentionally disabled.

Two options for getting a runtime in your dev checkout:

1. Run `fend setup --build-from-source`. This invokes
   `swift/scripts/prepare-runtime.sh`, which downloads the Ubuntu cloud
   kernel, builds the initramfs, and produces `~/.fend/runtime/` from
   scratch via Docker. Slow (~5–10 min) and needs Docker, but is the
   only way to test boot/runtime changes without cutting a release.
2. Set `FEND_DEV=1` and copy a runtime directory built elsewhere. Useful
   when iterating on the host code and the guest image hasn't changed.

`fend doctor` reports "developer (.git at …)" or "developer
(FEND_DEV=1)" in the contributor-tools section when it detects either
of these, and softens Docker/Rust warnings accordingly.

## Building

Swift CLI + daemon:

```bash
make -C swift sign
```

Rust guest agent:

```bash
cd fendd && cargo build --release --target aarch64-unknown-linux-musl
```

## Running tests

Swift:

```bash
swift test --package-path swift
```

Rust guest agent:

```bash
cd fendd && cargo test
```

## Branch and PR conventions

- Create feature branches from `main`
- Use conventional commits such as `feat:`, `fix:`, `docs:`, `chore:`, `ci:`
- Signed commits are required
- Open one focused pull request per change set
- PRs are squash-merged into `main`

## What makes a good PR

- Small and focused on one problem
- Includes tests or explains why tests are not practical
- Updates docs when behavior, setup, or user-facing output changes
- Updates [ARCHITECTURE.md](./ARCHITECTURE.md) if the architecture or VM model
  changed in a meaningful way
- Calls out follow-up work instead of trying to hide unfinished edges

## Before you open a PR

- Rebase onto current `main`
- Run the relevant local test commands
- Check that new files and scripts use concise, clear naming
- Redact any logs or examples that contain local paths, tokens, or secrets
