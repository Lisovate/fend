# Roadmap

Fend is in the first public alpha phase.

## Current focus

- macOS Apple Silicon public alpha polish
- proper npm distribution
- Developer ID signing and Apple notarization
- end-to-end soak on real projects

## Next up

### macOS Intel

- Evaluate the support cost versus demand
- Reuse as much of the current Swift/Virtualization framework path as possible

### Linux

- Keep the product shape aligned with macOS: one command, one project VM,
  project directory mounted in, secrets outside the VM, and per-command network
  policy
- The Linux host implementation lives in Rust under `linux/`
- The Linux path already has a validated QEMU/KVM spike, disposable
  `fend <command>`, first-run runtime bootstrap, working `npm run dev` port
  forwarding, and local npm package verification
- It is not yet published or supported as a release
- Follow the full Linux productization plan in
  [docs/linux-backend.md](./linux-backend.md)

### Windows

- Investigate a WSL2-backed path first
- Do not commit to a native Windows hypervisor backend until the product shape
  is proven

## Longer-term ideas

- AI-assisted package review via `agent-ws`
- macOS app with a secrets vault and dashboard
- IDE integration

## Roadmap notes

- Roadmap items are directional, not promises
- Alpha feedback should shape priority, especially around platform support and
  real-project workflows
