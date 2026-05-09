![CI](https://github.com/Lisovate/fend/actions/workflows/ci.yml/badge.svg) ![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg) ![Platform: macOS%20arm64](https://img.shields.io/badge/platform-macOS%20arm64-111827) ![Status: alpha](https://img.shields.io/badge/status-alpha-f59e0b)

# fend

**Fend off risky dependencies.** A sandboxed runtime for `npm install` and friends.

`npm install` still runs arbitrary third-party code as your user, and recent supply-chain attacks have shown how little friction that takes in practice. Incidents around packages used by teams depending on Axios, Bitwarden CLI, and SAP's Mini Shai-Hulud demonstrate the same pattern: once install-time code executes on the host, secrets and developer environments are in scope. Existing tooling mostly catches known bad packages after the fact. Fend takes the opposite approach and assumes package execution is hostile by default.

```bash
fend npm install        # runs npm install inside a micro-VM
fend npm run dev        # dev server is sandboxed too; ports forward back
fend audit              # OSV.dev advisory check across the lockfile
fend audit --fix        # propose + apply safe upgrades
```

> **Status: alpha.** macOS Apple Silicon is the only released platform today.
> The Swift CLI, the Rust guest agent, the warm-VM daemon, port forwarding,
> the shell hook, and the audit flow all work end-to-end there. Linux x86_64
> now has a working Rust `fend` path with real QEMU/KVM validation on Arch,
> automatic first-run runtime setup, disposable command execution, working
> `npm run dev` port forwarding, and a real npm pack/install workflow in the
> repo, but that Linux path is not published or supported as a release yet.
> Windows remains roadmap-only.

---

## Why

When you run `npm install`, any package can define `preinstall`/`postinstall` scripts that execute arbitrary code with your full user permissions. A rogue dep can silently read `~/.ssh/id_rsa`, `~/.aws/credentials`, scan for `.env` files, install background processes, hit the macOS Keychain — anything your account can touch.

`npm audit` only catches *known* CVEs. Node's experimental permission model is opt-in and unused. macOS protects system files but your home directory — where the valuable stuff lives — is wide open.

**fend assumes everything is hostile and isolates execution from your machine.** Your code stays native and you edit it normally. The moment something needs to *execute* — `npm install`, `npm run dev`, `npm test` — it runs inside a lightweight micro-VM with VirtioFS access to *only* the project directory. Nothing else on your machine is reachable.

This is the browser security model applied to local development.

---

## Quickstart

```bash
# macOS from source (see "Build from source" below)
make -C swift sign
sudo cp swift/.build/release/fend /usr/local/bin/fend

# first run auto-prepares the guest runtime (~1.5 GB today on Linux because
# rootfs.img is built locally with Docker; cached afterward in ~/.fend/runtime)
fend npm install

# everything else is just `fend <command>`
fend npm run dev        # dev server runs in the VM, port 3000 forwards to host
fend npm test
fend node scripts/seed.js
fend --network off npm test
```

### Shell hook (no prefix)

If you don't want to type `fend` every time, install the shell hook:

```bash
# zsh
echo 'eval "$(fend hook zsh)"' >> ~/.zshrc

# bash
echo 'eval "$(fend hook bash)"' >> ~/.bashrc

# then in any project
cd my-project
fend on                  # npm/bun/pnpm/yarn/node/python now route through fend
npm install              # sandboxed
npm run dev              # sandboxed
fend off                 # back to normal
```

### Audit

`fend audit` queries [OSV.dev](https://osv.dev/) for advisories against everything in your `package-lock.json` and prints a unified report:

```bash
fend audit               # report only
fend audit --fix         # apply safe in-range upgrades + overrides
fend audit --fix --force # also apply major-version bumps
fend audit --json        # structured output for CI
```

The audit also runs automatically before `fend npm install`. Findings show up as:

```
warn  3 advisories found  worst HIGH
  packages  2 of 412 packages
  duration  1.1s

Package   Current  Fix                 Worst     Advisories
minimist  1.2.0    1.2.6 override      HIGH      GHSA-xvch-5gv4-984h
lodash    3.10.1   4.17.21 needs --force CRITICAL GHSA-jf85-cpcp-j695

  HIGH minimist: Prototype pollution in minimist [GHSA-xvch-5gv4-984h]
  CRITICAL lodash: Prototype pollution in defaultsDeep [GHSA-jf85-cpcp-j695]

info  fix plan  1 auto-fixable, 1 major bump (--force)
```

### Planned: AI-assisted package review

Fend's install flow is designed to support a future AI review gate between
`npm install --ignore-scripts` and `npm rebuild`: install packages without
lifecycle scripts first, collect evidence about risky/new/scripted packages,
ask an AI reviewer for a structured verdict, then decide whether scripts should
run.

The first integration target is [`agent-ws`](https://www.npmjs.com/package/agent-ws),
a local WebSocket bridge for Claude Code and Codex CLI. That keeps provider
tokens outside Fend by default and lets users reuse their existing CLI agent
authentication. The intended role is advisory/gating support — AI can explain
and flag suspicious dependency behavior, but it cannot prove a package is safe.

Likely review inputs:

- new or changed packages from the lockfile
- lifecycle scripts (`preinstall`, `install`, `postinstall`, `prepare`)
- selected package files such as `package.json` and install scripts
- OSV audit findings
- network and filesystem evidence from the sandbox

Possible future config shape:

```toml
[ai]
enabled = false
provider = "agent-ws"               # agent-ws | openai | anthropic
url = "ws://localhost:9999"
token_env = "FEND_AGENT_WS_TOKEN"
mode = "report"                     # report | warn | block
scope = "risky"                     # risky | new | direct | all
max_packages = 25
```

### Run Claude Code sandboxed

```bash
fend claude              # runs `claude` with your Anthropic OAuth token injected,
                         # nothing else from your machine reachable
fend claude <cmd>        # run anything else with the same env
```

---

## Configuration

Drop a `.fend.toml` at the project root. Every field is optional.

```toml
[runtime]
node = "22"                          # pin the Node version inside the VM
bun  = "1.1"

[vm]
cpus = 2
memory = "2GB"

[network]
mode = "on"                         # on | off

[watch]
mode = "auto"                       # auto | native | polling | mirror
poll_interval_ms = 500              # used when polling is active

[audit]
level = "strict"                     # strict | warn | off
rebuild = true                       # run `npm rebuild` after a clean audit
auto_approve_in_ci = false           # skip prompts when $CI is set
block = ["malware", "critical"]      # severities that halt the install
prompt = ["high"]                    # severities that require y/N confirmation
fix_on_install = true                # offer to apply safe fixes before install
include_prerelease = false           # consider pre-release versions when fixing
```

Generate one with `fend init`.

Use `mode = "off"` or `fend --network off <command>` for commands that should
not reach the internet, such as tests or risky install-script rebuilds. The
network mode is recorded in `fend log` for later review.

`[watch]` controls file-change detection for long-running dev servers. Today
`auto` keeps macOS on native VirtioFS notifications and switches likely Linux
dev commands to polling for compatibility with current VirtioFS host-to-guest
watcher limits. You can override one command with `fend --watch polling npm run
dev` or force native behavior with `fend --watch native npm run dev`. `mirror`
is reserved for the planned Linux mode where host source files are copied into
a disposable guest-local workspace for better HMR behavior.

Useful log filters:

```bash
fend log --network off
fend log --network-events
fend log --fs-risk high
fend log --audit-decision blocked
fend log --failed
```

Use `fend log --json` to inspect structured filesystem and network evidence
for a specific run.

### Terminal output

Human output is intentionally compact: status labels, small tables, and hints
for common failure modes. Guest command stdout/stderr is passed through
unchanged so tools like `npm`, `node`, and test runners still behave normally.

Useful environment controls:

```bash
NO_COLOR=1 fend npm test          # disable ANSI colors
FEND_VERBOSE=1 fend npm run dev   # include daemon/debug status lines
FEND_QUIET=1 fend npm test        # suppress non-warning host status
FEND_FORCE_COLOR=1 fend log       # force color even when auto-detection says no
```

---

## How it works

`fend <command>` wraps any shell command in a sandboxed VM. On macOS that's [Apple's Virtualization.framework](https://developer.apple.com/documentation/virtualization) running a stripped-down Linux with [VirtioFS](https://virtio-fs.gitlab.io/) for the project directory mount. The first invocation per project boots a VM (~1s); subsequent invocations reuse a warm VM (auto-paused after 5 minutes idle).

A small Rust binary (`fendd`) runs as PID 1 inside the VM, talks to the host over virtio-vsock, manages port forwarding, and supervises the user's command.

The VM can read/write the project directory and, by default, reach the network.
Per-command network access can be disabled with `--network off`. It cannot see
`~/.ssh`, `~/.aws`, `~/Library`, `~/.gnupg`, `.env` files outside the project,
or any other path on the host.

For deep architecture detail — VM lifecycle, scenarios, file-watching/HMR strategy, VirtioFS performance, system diagrams — see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

---

## Build from source

You'll need Xcode 15+ (Swift 5.9+), Rust, and Docker.

```bash
# Swift CLI + daemon
make -C swift sign       # builds release binary, ad-hoc codesigns with the
                         # virtualization entitlement
swift/.build/release/fend --help

# Rust guest agent (cross-compiled to aarch64-musl, baked into the rootfs)
cd fendd && cargo build --release --target aarch64-unknown-linux-musl

# Run tests
swift test --package-path swift
```

On macOS, the first `fend <anything>` call runs `swift/scripts/prepare-runtime.sh`
and prepares `~/.fend/runtime/`. On Linux x86_64, the Rust binary now owns
that flow: `fend setup` prepares `~/.fend/runtime/linux-x86_64`, and normal
`fend <command>` runs bootstrap it automatically when needed.

### Packaging for npm

`scripts/build-binary.sh` stages the macOS Apple Silicon binary into
`packages/cli-darwin-arm64/bin/`. `scripts/build-linux-binary.sh` stages the
Linux x64 host `fend` binary plus the packaged `fendd` guest agent into
`packages/cli-linux-x64/`. The JS wrapper at `bin/fend.js` resolves the right
platform package via npm's `optionalDependencies`, falling back to monorepo
artifacts during local development.

For local release verification:

- `./scripts/pack-npm.sh --platform linux-x64` builds/stages the Linux binaries
  and emits the root + platform `.tgz` packages.
- `./scripts/test-linux-npm-package.sh` installs those tarballs into a throwaway
  npm prefix and verifies the installed `fend` wrapper end to end.
- `./scripts/publish-npm.sh --platform linux-x64 --dry-run` checks the publish
  order and package contents without touching the registry.

Publishing requires Developer ID signing + Apple notarization — Apple Virtualization entitlements are otherwise rejected at runtime on end-user machines. The current build script only ad-hoc signs.

---

## Roadmap

- **Now:** macOS Apple Silicon. Polishing for the first public release (proper npm distribution, Developer ID notarization, end-to-end soak on real projects).
- **Next:** macOS Intel.
- **Then:** Linux via KVM/QEMU first, with a smaller custom backend evaluated later. See [`docs/linux-backend.md`](./docs/linux-backend.md).
- **Linux path in progress:** Linux host work lives separately in Rust under
  `linux/`; the crate now exposes both `fend-linux` and a Linux `fend`
  binary, supports `fend doctor`, `fend setup`, disposable `fend <command>`
  runs, automatic fallback from missing `passt` to QEMU user networking, and
  real guest command execution with QEMU/KVM and `virtiofsd`. Packaging and
  local install verification are wired for `@fendsh/cli-linux-x64` in the
  repo, but the Linux npm path is not published yet.
- **Future:** Windows (WSL2), AI-assisted package review via `agent-ws`, macOS app with secrets vault and dashboard, IDE integration.

Issues, bug reports, and PRs welcome.

---

## Security

Fend is a security tool, so the repo treats supply-chain and disclosure hygiene
as part of the product. Signed commits, branch protection, and private
vulnerability disclosure are part of the expected release process. See
[SECURITY.md](./SECURITY.md) for the reporting policy and response expectations.

## Contributing

If you want to contribute, start with [CONTRIBUTING.md](./CONTRIBUTING.md) for
build/test expectations and [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) for the
community ground rules. Small, focused PRs with tests and relevant docs updates
are the easiest to review.

---

## License

MIT — see [LICENSE](./LICENSE).

---

## Acknowledgements

Standing on the shoulders of:

- [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization) — the macOS hypervisor that makes sub-second VM boot tractable
- [Apple Containerization](https://github.com/apple/containerization) — validates the VM-per-workload approach
- [VirtioFS](https://virtio-fs.gitlab.io/) — near-native shared filesystem performance
- [OSV.dev](https://osv.dev/) — open vulnerability database powering `fend audit`
- [OrbStack](https://orbstack.dev/) — proof that VMs on Mac can feel native
- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
