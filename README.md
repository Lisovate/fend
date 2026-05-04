# fend

**Fend off risky dependencies.** A sandboxed runtime for `npm install` and friends.

```bash
fend npm install        # runs npm install inside a micro-VM
fend npm run dev        # dev server is sandboxed too; ports forward back
fend audit              # OSV.dev advisory check across the lockfile
fend audit --fix        # propose + apply safe upgrades
```

> **Status: alpha — macOS Apple Silicon only.** The Swift CLI, the Rust guest
> agent, the warm-VM daemon, port forwarding, the shell hook, and the audit
> flow all work end-to-end. The npm package (`@fendsh/cli`) is still a
> placeholder; for now you build from source. Linux & Windows are on the
> roadmap, not in this release.

---

## Why

When you run `npm install`, any package can define `preinstall`/`postinstall` scripts that execute arbitrary code with your full user permissions. A rogue dep can silently read `~/.ssh/id_rsa`, `~/.aws/credentials`, scan for `.env` files, install background processes, hit the macOS Keychain — anything your account can touch.

`npm audit` only catches *known* CVEs. Node's experimental permission model is opt-in and unused. macOS protects system files but your home directory — where the valuable stuff lives — is wide open.

**fend assumes everything is hostile and isolates execution from your machine.** Your code stays native and you edit it normally. The moment something needs to *execute* — `npm install`, `npm run dev`, `npm test` — it runs inside a lightweight micro-VM with VirtioFS access to *only* the project directory. Nothing else on your machine is reachable.

This is the browser security model applied to local development.

---

## Quickstart

```bash
# build from source (see "Build from source" below)
make -C swift sign
sudo cp swift/.build/release/fend /usr/local/bin/fend

# first run downloads the Linux kernel + builds a rootfs image (~1.5 GB,
# requires Docker; one-time, cached in ~/.fend/runtime)
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

You'll need Xcode 15+ (Swift 5.9+), Rust (for the guest agent), and Docker (one-time, to build the Linux rootfs image on first run).

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

First time you run `fend <anything>`, `swift/scripts/prepare-runtime.sh` fires and prepares `~/.fend/runtime/` (kernel + initrd + rootfs.img). Takes a few minutes; cached afterward.

### Packaging for npm

`scripts/build-binary.sh` builds a release binary and stages it into `packages/cli-darwin-arm64/bin/` so the JS wrapper at `bin/fend.js` can find it. The wrapper resolves the correct platform package via npm's `optionalDependencies`, falling back to the monorepo path during local development.

Publishing requires Developer ID signing + Apple notarization — Apple Virtualization entitlements are otherwise rejected at runtime on end-user machines. The current build script only ad-hoc signs.

---

## Roadmap

- **Now:** macOS Apple Silicon. Polishing for the first public release (proper npm distribution, Developer ID notarization, end-to-end soak on real projects).
- **Next:** macOS Intel.
- **Then:** Linux (Firecracker), Windows (WSL2).
- **Later:** AI-assisted package review via `agent-ws`, macOS app with secrets vault and dashboard, IDE integration.

Issues, bug reports, and PRs welcome.

---

## Acknowledgements

Standing on the shoulders of:

- [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization) — the macOS hypervisor that makes sub-second VM boot tractable
- [Apple Containerization](https://github.com/apple/containerization) — validates the VM-per-workload approach
- [VirtioFS](https://virtio-fs.gitlab.io/) — near-native shared filesystem performance
- [OSV.dev](https://osv.dev/) — open vulnerability database powering `fend audit`
- [OrbStack](https://orbstack.dev/) — proof that VMs on Mac can feel native
- [swift-argument-parser](https://github.com/apple/swift-argument-parser)

---

## License

MIT — see [LICENSE](./LICENSE).
