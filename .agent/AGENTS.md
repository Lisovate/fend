# Fend

Sandboxed runtime that isolates package installs and dev scripts from your machine.

## Status

macOS Apple Silicon MVP is implemented end-to-end (Swift CLI, daemon, warm-VM lifecycle, VirtioFS, port forwarding, shell hook, OSV audit + `--fix`). Pre-release polish: npm distribution, Developer ID notarization, real-project soak.

## Tech Stack

- **macOS CLI + daemon:** Swift + Apple Virtualization.framework (`swift/`)
- **Guest agent (fendd):** Rust, runs as PID 1 inside the VM (`fendd/`)
- **Linux host implementation:** Rust (`linux/`, early QEMU/KVM planning code)
- **Windows CLI:** Rust (not started)
- **Filesystem:** VirtioFS for project directory mounting
- **Config:** `.fend.toml`
- **Host↔VM protocol:** virtio-vsock with custom binary framing

## Key Concept

`fend <command>` wraps any shell command in a sandboxed VM. The VM can access the project directory (mounted via VirtioFS) but nothing else on the host (no ~/.ssh, ~/.aws, ~/Library, etc.).

## Reference

- `README.md` — user-facing docs (install, quickstart, configuration)
- `ARCHITECTURE.md` — VM lifecycle, scenarios, design decisions, system diagrams
- `../ROADMAP.md` *(outside the public repo)* — full strategy, business model, marketing plan
- `swift/` — macOS Swift CLI + daemon implementation
- `linux/` — separate Rust Linux host implementation
- `fendd/` — Rust guest agent
