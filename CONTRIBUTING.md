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
- Docker for first-run rootfs image preparation

Install the Rust target with:

```bash
rustup target add aarch64-unknown-linux-musl
```

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
