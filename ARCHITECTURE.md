# Fend Developer Workflow Architecture

Detailed design of how `fend` handles real-world frontend development workflows. This document covers every step of the developer experience from cold start to warm reuse, with concrete terminal output, timing, and architectural decisions grounded in research of existing tools (Docker Desktop, OrbStack, devcontainers, Apple Containerization).

---

## Table of Contents

1. [What's Inside the VM](#1-whats-inside-the-vm)
2. [VM Lifecycle & The "Warm VM" Experience](#2-vm-lifecycle--the-warm-vm-experience)
3. [Scenario 1: Fresh Project Setup (`fend npm install`)](#3-scenario-1-fresh-project-setup)
4. [Scenario 2: Running a Dev Server (`fend npm run dev`)](#4-scenario-2-running-a-dev-server)
5. [Scenario 3: Running Tests Concurrently (`fend npm test`)](#5-scenario-3-running-tests-concurrently)
6. [Scenario 4: Environment Variables (`fend --env-file`)](#6-scenario-4-environment-variables)
7. [Scenario 5: pnpm Support](#7-scenario-5-pnpm-support)
8. [Scenario 6: Shell Hook Mode (`fend on`)](#8-scenario-6-shell-hook-mode)
9. [Key Architecture Decision: node_modules Location](#9-key-architecture-decision-node_modules-location)
10. [Key Architecture Decision: File Watching & HMR](#10-key-architecture-decision-file-watching--hmr)
11. [Key Architecture Decision: VirtioFS Performance](#11-key-architecture-decision-virtiofs-performance)
12. [Architecture Diagrams](#12-architecture-diagrams)

---

## 1. What's Inside the VM

### Base Image

The fend VM runs a minimal Linux image purpose-built for speed, not generality. It is NOT a full distro. Think Alpine-minimal crossed with Apple's vminitd approach.

```
fend-base-image/
├── vmlinux                    # Custom arm64 Linux kernel (~10MB)
│                              # Optimized config: VIRTIO compiled in (not modules),
│                              # stripped drivers, no GPU/sound/USB, minimal scheduler
│                              # Based on kernel 6.14+ for best VirtioFS support
├── initrd                     # Minimal initramfs (~3MB)
│   ├── /sbin/fendd            # Fend's init process (Rust static binary)
│   ├── /bin/busybox           # Coreutils (ls, cat, sh, etc.)
│   ├── /lib/musl-libc.so      # Minimal libc
│   └── /etc/resolv.conf       # DNS config (points to host gateway)
└── overlays/                  # Layered tool images
    ├── node-20.tar.zst        # Node.js 20 LTS (~25MB compressed)
    ├── node-22.tar.zst        # Node.js 22 LTS
    ├── python-3.12.tar.zst    # Python 3.12
    └── bun-1.1.tar.zst        # Bun runtime
```

### fendd (init process)

Replaces systemd/openrc. Inspired by Apple Containerization's vminitd but written for fend's use case.

Responsibilities:
- PID 1: spawns and supervises all processes
- Mounts VirtioFS shares from host
- Sets up networking (virtio-net, NAT via host)
- Exposes gRPC API over virtio-vsock to the host CLI
- Receives commands, env vars, signals from host
- Streams stdout/stderr back to host via vsock
- Manages port forwarding table
- Handles graceful shutdown

```
fendd boot sequence (~200ms):
  0ms   - kernel hands off to fendd
  10ms  - mount /proc, /sys, /dev
  20ms  - mount VirtioFS share → /workspace
  40ms  - configure eth0 via DHCP (virtio-net)
  60ms  - load tool overlay (e.g., node-20) → /usr/local/
  100ms - open vsock listener on port 1024
  200ms - send READY signal to host CLI
```

### How the User Controls What's in the VM

Three mechanisms, in priority order:

**1. Auto-detection (zero config)**
```
fend reads package.json → engines.node → selects matching overlay
fend reads .python-version → selects matching overlay
fend reads .tool-versions (asdf) → selects matching overlays
```

**2. `.fend.toml` config file**
```toml
[runtime]
node = "20"           # Pin Node.js version
tools = ["python:3.12", "bun:1.1"]  # Additional tools

[vm]
memory = "4GB"        # Default: 2GB
cpus = 4              # Default: 2
```

**3. CLI flags**
```bash
fend --node 18 npm install    # Override for one command
fend --memory 8GB npm run build
```

**What if the project needs Node 18 but the VM has Node 20?**

On first `fend` invocation for a project, fend reads `package.json` > `engines.node`. If it specifies `">=18 <19"`, fend downloads and caches the Node 18 overlay (~25MB compressed, <2s on broadband). Overlays are content-addressed and shared across projects. Once cached, switching is instant (mount a different overlay directory).

```
$ fend npm install
  fend: project requires node 18.x (from package.json engines)
  fend: downloading node-18 overlay... done (1.8s)
  fend: booting VM... ready (0.8s)
  fend: running npm install...
```

---

## 2. VM Lifecycle & The "Warm VM" Experience

### State Machine

```
                 fend <cmd>              idle 5min           fend <cmd>
  [Not Running] ─────────→ [Running] ─────────→ [Paused] ─────────→ [Running]
       │                      │                     │                    │
       │ cold boot            │ warm dispatch       │ resume             │
       │ ~800ms               │ ~5ms                │ ~100ms             │
       └──────────────────────┴─────────────────────┴────────────────────┘
                                                    │
                                            idle 30min / fend stop
                                                    │
                                                    ▼
                                              [Not Running]
```

### Timing Breakdown

| Transition | Duration | What Happens |
|---|---|---|
| Cold boot | ~800ms | Kernel boot → fendd init → VirtioFS mount → overlay load → vsock ready |
| Warm dispatch | ~5ms | CLI connects to existing vsock, sends command, fendd forks process |
| Pause | instant | `SIGSTOP` the VM process (macOS freezes all VM threads) |
| Resume | ~100ms | `SIGCONT` → fendd re-validates VirtioFS mount → ready |
| Shutdown | ~200ms | fendd sends SIGTERM to children → unmount → exit |

### Visual Indicators

The fend CLI shows a subtle status line, but stays out of the way:

```
$ fend npm install
  fend: vm ready (0.8s)           ← only shown on cold boot
  npm install                      ← rest is standard npm output
  ...

$ fend npm test                   ← second command, VM already warm
  npm test                         ← no fend prefix, instant start
  ...
```

A background indicator (optional, for the macOS app):
- Menu bar icon: green dot when VM is running, yellow when paused, gray when stopped
- `fend status` command shows all project VMs and their state

```
$ fend status
  PROJECT          VM STATE    UPTIME    MEM     CPU
  ~/repos/my-app   running     12m       512MB   0.1%
  ~/repos/api      paused      (5m ago)  256MB   0.0%
```

---

## 3. Scenario 1: Fresh Project Setup

**Starting point:** User has cloned a Next.js project. `package.json` exists, no `node_modules`.

```bash
cd ~/repos/my-app
fend npm install
```

### Step-by-Step Flow

```
TIMELINE
────────────────────────────────────────────────────────────

T+0ms     USER types: fend npm install

T+1ms     HOST: fend CLI parses arguments
          - command = ["npm", "install"]
          - project dir = ~/repos/my-app (cwd)

T+5ms     HOST: fend checks for existing VM for ~/repos/my-app
          - looks up ~/.fend/state/vms.json
          - no VM found → cold boot path

T+10ms    HOST: fend reads ~/repos/my-app/package.json
          - engines.node = ">=20" → selects node-20 overlay
          - overlay already cached at ~/.fend/overlays/node-20.tar.zst

T+15ms    HOST: fend creates VM via Apple Virtualization.framework
          - VZVirtualMachineConfiguration:
            - 2 CPUs, 2GB RAM (defaults)
            - VZVirtioFileSystemDeviceConfiguration:
                tag: "workspace"
                share: ~/repos/my-app → /workspace (read-write)
            - VZVirtioFileSystemDeviceConfiguration:
                tag: "overlay"
                share: ~/.fend/overlays/node-20/ → /usr/local (read-only)
            - VZVirtioFileSystemDeviceConfiguration:
                tag: "cache"
                share: ~/.fend/cache/npm/ → /root/.npm (read-write)
            - VZNATNetworkDeviceAttachment (internet access)
            - VZVirtioSocketDeviceConfiguration (vsock control channel)

T+800ms   VM: fendd sends READY over vsock

T+810ms   HOST: fend CLI receives READY
          - establishes gRPC channel over vsock
          - sends ExecuteCommand {
              cmd: ["npm", "install"],
              cwd: "/workspace",
              env: { HOME: "/root", PATH: "/usr/local/bin:/bin" },
              tty: true,
              stdout_stream: true,
              stderr_stream: true,
            }

T+820ms   VM: fendd forks, execs: npm install
          - npm reads /workspace/package.json
          - npm creates /workspace/node_modules/
          - npm downloads packages from registry (via VM's NAT network)
          - npm writes packages to /workspace/node_modules/
          - All writes go through VirtioFS → appear on host filesystem

T+820ms   HOST: fend CLI streams stdout/stderr to user's terminal
          User sees:

          ┌──────────────────────────────────────────────┐
          │ $ fend npm install                           │
          │   fend: vm ready (0.8s)                      │
          │                                              │
          │ npm warn deprecated inflight@1.0.6           │
          │ npm warn deprecated glob@7.2.3               │
          │                                              │
          │ added 387 packages in 28s                    │
          │                                              │
          │ 142 packages are looking for funding          │
          │   run `npm fund` for details                 │
          └──────────────────────────────────────────────┘

T+29s     VM: npm exits with code 0
          VM: fendd sends ExitStatus { code: 0 } over vsock

T+29s     HOST: fend CLI exits with code 0
          HOST: VM stays running (warm for next command)
```

### Where Does node_modules End Up?

**On the host filesystem, via VirtioFS.** This is the critical architectural decision.

```
~/repos/my-app/
├── package.json
├── node_modules/        ← written by VM, visible on host
│   ├── next/
│   ├── react/
│   ├── typescript/
│   └── .package-lock.json
├── src/
└── .fend.toml
```

The VM writes to `/workspace/node_modules/` which is a VirtioFS mount pointing to `~/repos/my-app/node_modules/` on the host. The files appear immediately on the host filesystem.

### Where Does the npm Cache Live?

**On the host, in a shared cache directory, mounted into the VM.**

```
Host:  ~/.fend/cache/npm/       →  VM: /root/.npm/
```

This means:
- npm cache is shared across all projects (same as native behavior)
- Second `npm install` in a different project reuses cached packages
- Cache survives VM restarts
- Cache can be cleared with `fend cache clean`

### What Does VS Code See?

VS Code (running on the host) sees the full `node_modules/` directory because it exists on the host filesystem. TypeScript language server resolves types normally.

```
VS Code experience:
  - node_modules/ appears in file explorer ✓
  - Cmd+click on import jumps to node_modules source ✓
  - TypeScript errors/completions work ✓
  - .d.ts files resolve correctly ✓
  - No special extension or remote connection needed ✓
```

This is the key advantage over devcontainers: **the IDE works completely natively.**

### How Long Does This Take vs Native?

| Operation | Native | Fend (cold boot) | Fend (warm VM) | Overhead |
|---|---|---|---|---|
| VM startup | N/A | ~800ms | 0ms | one-time |
| npm install (empty cache) | ~25s | ~28s | ~27s | ~10% slower |
| npm install (cached) | ~8s | ~10s | ~9s | ~15% slower |
| npm ci (clean) | ~15s | ~18s | ~17s | ~15% slower |

The overhead comes from VirtioFS I/O for writing ~30,000 files to `node_modules/`. Network speed is identical (same internet connection via NAT). The ~10-15% overhead is acceptable -- OrbStack achieves 88% of native speed for `pnpm install` with their VirtioFS + caching optimizations, and fend can adopt similar strategies.

---

## 4. Scenario 2: Running a Dev Server

```bash
fend npm run dev
```

### Step-by-Step Flow

```
TIMELINE
────────────────────────────────────────────────────────────

T+0ms     USER types: fend npm run dev

T+1ms     HOST: fend CLI detects existing VM for ~/repos/my-app
          - VM is running (warm from npm install)
          - vsock connection established in ~5ms

T+10ms    HOST: fend sends ExecuteCommand over vsock
          {
            cmd: ["npm", "run", "dev"],
            cwd: "/workspace",
            env: { ... },
            tty: true,
            interactive: true,    ← keep stdin open for Ctrl+C
            port_forward: "auto", ← detect and forward listening ports
          }

T+15ms    VM: fendd forks, execs: npm run dev
          - next dev starts
          - Reads files from /workspace/src/ (VirtioFS)
          - Compiles TypeScript, bundles with Turbopack/webpack
          - Starts HTTP server on 0.0.0.0:3000 inside VM

T+2.5s    VM: next dev binds to port 3000
          VM: fendd detects new listening socket (via netlink/ss polling)
          VM: fendd sends PortOpened { guest_port: 3000 } over vsock

T+2.5s    HOST: fend CLI receives PortOpened
          HOST: fend creates TCP listener on host localhost:3000
          HOST: fend forwards connections:
            host localhost:3000 → vsock → VM 0.0.0.0:3000

T+3s      User sees:

          ┌──────────────────────────────────────────────┐
          │ $ fend npm run dev                           │
          │                                              │
          │ > my-app@0.1.0 dev                           │
          │ > next dev                                   │
          │                                              │
          │   ▲ Next.js 15.1.0                           │
          │   - Local:    http://localhost:3000           │
          │   - Network:  http://192.168.64.2:3000       │
          │                                              │
          │   fend: forwarding localhost:3000 → vm:3000  │
          │                                              │
          │  ✓ Ready in 2.8s                             │
          └──────────────────────────────────────────────┘

T+3s      USER opens http://localhost:3000 in browser
          HOST: TCP connection on localhost:3000
          HOST: fend proxy forwards to VM via vsock
          VM: Next.js serves the page
          Response flows back: VM → vsock → host proxy → browser
```

### How Port Forwarding Works

```
┌─────────────────────────────────────────────────────────────┐
│ HOST (macOS)                                                │
│                                                             │
│  Browser ──→ localhost:3000 ──→ [fend port proxy] ──┐       │
│                                                     │       │
│                                        vsock (virtio)       │
│                                                     │       │
│  ┌──────────────────────────────────────────────────┼──┐    │
│  │ VM (Linux)                                       │  │    │
│  │                                                  │  │    │
│  │  [fendd port router] ←───────────────────────────┘  │    │
│  │         │                                           │    │
│  │         └──→ 0.0.0.0:3000 ──→ [Next.js dev server]  │    │
│  │                                                     │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

Port detection is automatic. fendd periodically polls `/proc/net/tcp` or uses netlink sockets to detect new listening ports inside the VM. When a new port appears, it notifies the host CLI, which creates a corresponding listener. No manual port mapping needed.

If port 3000 is already in use on the host, fend picks the next available port and tells the user:

```
  fend: port 3000 in use on host, forwarding localhost:3001 → vm:3000
```

### How HMR (Hot Module Reload) Works

This is the most latency-sensitive path. Here's the full chain:

```
USER edits src/app/page.tsx in VS Code (on host)
  │
  │  macOS writes file to host filesystem
  │
  ▼
VirtioFS propagates change to VM
  │
  │  VirtioFS supports inotify for MODIFY events
  │  (CREATE and MODIFY work reliably; DELETE has known gaps)
  │
  ▼
VM: chokidar/watchpack detects file change via inotify
  │
  │  Next.js/Turbopack receives change notification
  │  Recompiles the changed module (~50-200ms)
  │
  ▼
VM: Next.js sends HMR update via WebSocket
  │
  │  WebSocket connection: browser ↔ localhost:3000 ↔ vsock ↔ VM:3000
  │
  ▼
Browser: receives HMR payload, hot-swaps module
  │
  │  React re-renders the changed component
  │
  ▼
USER sees updated UI

Total latency: ~200-500ms (vs ~100-300ms native)
  - VirtioFS inotify propagation: ~10-50ms
  - Recompilation: ~50-200ms (same as native, CPU bound)
  - WebSocket round trip through proxy: ~5ms
  - Overhead vs native: ~100-200ms, mostly VirtioFS notification delay
```

**Critical detail: inotify limitations.** VirtioFS supports inotify for file MODIFY and CREATE events, but DELETE events have known gaps in some implementations. For HMR this is acceptable because:
- File edits (MODIFY) are the primary HMR trigger, and these work
- File creation (new components) also works
- File deletion rarely triggers HMR (usually requires a page reload anyway)

**Fallback: polling mode.** If a project's file watcher doesn't receive inotify events reliably, fend can inject `CHOKIDAR_USEPOLLING=true` and `CHOKIDAR_INTERVAL=500` as a fallback. This uses ~2-5% more CPU but guarantees change detection. Next.js/Vite/webpack all support polling mode.

The fend daemon inside the VM can also run its own fsevents-to-inotify bridge (similar to OrbStack's fsnotify-macvirt approach): a small process that watches the VirtioFS mount for changes and generates synthetic inotify events to guarantee coverage of edge cases that raw VirtioFS misses.

### Can the User Ctrl+C?

Yes. Signal forwarding works through the vsock control channel:

```
User presses Ctrl+C
  │
  HOST: terminal sends SIGINT to fend CLI process
  │
  HOST: fend CLI sends Signal { sig: SIGINT } over vsock
  │
  VM: fendd delivers SIGINT to the running npm process
  │
  VM: Next.js dev server handles SIGINT, shuts down gracefully
  VM: process exits with code 130
  │
  VM: fendd sends ExitStatus { code: 130 } over vsock
  │
  HOST: fend CLI exits with code 130
```

Ctrl+C behavior is identical to running natively. The user does not need to know about the VM.

### What Happens to the VM After the Dev Server Stops?

The VM stays running. It enters the warm state, ready for the next command:

```
$ fend npm run dev
  ... (running for 2 hours) ...
  ^C                            ← user stops dev server

$ fend npm test                 ← instant start, VM still warm
  ...
```

After 5 minutes of no commands, the VM is paused (SIGSTOP). After 30 minutes, it's shut down. These timeouts are configurable in `.fend.toml`.

---

## 5. Scenario 3: Running Tests Concurrently

```bash
# Terminal 1 (dev server still running):
fend npm run dev

# Terminal 2:
fend npm test
```

### Same VM or Different VM?

**Same VM.** Multiple commands in the same project share one VM.

```
┌─────────────────────────────────────────────────────┐
│ VM for ~/repos/my-app                               │
│                                                     │
│   PID 1: fendd                                      │
│   PID 42: npm run dev (next dev, port 3000)         │
│   PID 87: npm test (jest, no port)                  │
│                                                     │
│   /workspace → ~/repos/my-app (VirtioFS)            │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Why same VM?**
- Both commands need the same `node_modules/` and project files
- No duplication of filesystem mounts or memory
- Processes can share the npm cache, tmp directories
- Consistent behavior with native development (both processes share the same OS)

**How it works:**

```
Terminal 2: fend npm test

T+0ms   HOST: fend CLI detects existing VM for ~/repos/my-app
        VM state: running (dev server active)

T+5ms   HOST: fend opens new vsock connection to fendd
        HOST: sends ExecuteCommand { cmd: ["npm", "test"], ... }

T+10ms  VM: fendd forks a new process for npm test
        Both processes run concurrently, sharing /workspace

T+15s   VM: jest finishes, exits with code 0
        VM: fendd sends ExitStatus to this specific vsock connection

T+15s   HOST: fend CLI in Terminal 2 exits with code 0
        Dev server in Terminal 1 continues unaffected
```

Each `fend` CLI instance maintains its own vsock connection to fendd. fendd multiplexes: each connection maps to one child process. stdout/stderr are routed to the correct CLI instance via connection ID.

### What About Resource Contention?

The VM has finite CPU/memory. Running tests while the dev server is active is normal (developers do this natively too). If the VM is under-resourced:

```toml
# .fend.toml
[vm]
cpus = 4        # Give more CPUs for concurrent workloads
memory = "4GB"
```

fendd does NOT attempt process isolation within the VM. All processes in the same project VM share the same Linux namespace. This is intentional: fend's threat model is protecting the HOST from the VM, not isolating processes within the VM.

---

## 6. Scenario 4: Environment Variables

### Inline Env Vars

```bash
DATABASE_URL=postgres://localhost:5432/mydb fend npm run seed
```

The fend CLI captures environment variables from the shell and forwards them:

```
T+0ms   HOST: shell expands env vars before exec
        fend receives: argv=["npm","run","seed"]
                       env includes DATABASE_URL=postgres://...

T+5ms   HOST: fend sends ExecuteCommand {
          cmd: ["npm", "run", "seed"],
          env: {
            DATABASE_URL: "postgres://localhost:5432/mydb",
            HOME: "/root",
            PATH: "/usr/local/bin:/bin",
            ... (filtered host env)
          }
        }

T+10ms  VM: fendd sets env vars and execs npm run seed
        The seed script can read process.env.DATABASE_URL
```

**Important:** fend does NOT forward the entire host environment. It uses an allowlist:

```
Forwarded by default:
  TERM, LANG, LC_*, COLORTERM, FORCE_COLOR, NO_COLOR,
  HOME (remapped to /root), USER (remapped to root),
  PATH (remapped to VM paths)

Forwarded when explicitly set by user (detected via env diff):
  DATABASE_URL, API_KEY, anything the user sets inline

Never forwarded:
  SSH_AUTH_SOCK, AWS_*, GITHUB_TOKEN, NPM_TOKEN,
  anything from ~/.zshrc that wasn't explicitly passed
```

### --env-file Flag

```bash
fend --env-file .env.local npm run seed
```

```
T+0ms   HOST: fend CLI reads .env.local from ~/repos/my-app/.env.local
        HOST: parses key=value pairs
        HOST: sends them as env vars in the ExecuteCommand message

T+5ms   VM: fendd injects env vars into the process environment
        The .env.local FILE is never copied into the VM
        The VALUES exist only in process memory
```

This is a security advantage: even if a malicious postinstall script scans the filesystem inside the VM, it won't find `.env.local` because it was never written to any filesystem the VM can see. The values exist only as process environment variables.

### Secrets Bridge (Pro/App Feature)

For the macOS app tier, secrets are stored in an encrypted vault and injected per-project:

```bash
fend npm run seed
# Secrets from vault are injected automatically, no --env-file needed
```

The vault is a macOS Keychain-backed encrypted store. Secrets are transmitted over the vsock channel (never touch disk in the VM).

---

## 7. Scenario 5: pnpm Support

```bash
fend pnpm install
```

### The pnpm Challenge

pnpm uses a fundamentally different approach than npm:
1. **Global content-addressable store** (`~/.local/share/pnpm/store/`) with hard-linked packages
2. **Symlinked node_modules** structure instead of flat copies
3. **Hard links** between store and project node_modules

This creates two problems with VirtioFS:

**Problem 1: Cross-device links.** The pnpm store and the project directory must be on the same filesystem for hard links to work. If they're on different VirtioFS mounts (or one is VirtioFS and the other is ext4), hard links fail with `EXDEV: cross-device link not permitted`.

**Problem 2: VirtioFS reliability.** pnpm + VirtioFS has documented issues (68% failure rate in Docker Desktop's VirtioFS tests as of 2024).

### Solution: Store and Project on Same Mount

```
VirtioFS mount:
  ~/repos/my-app/ → /workspace/

Strategy: put pnpm store INSIDE the project mount

fend sets: PNPM_HOME=/workspace/.pnpm-store
           (equivalent to ~/repos/my-app/.pnpm-store on host)
```

Both the store and `node_modules` live on the same VirtioFS mount, so hard links work. The `.pnpm-store` directory is per-project (not global), which means slightly more disk usage but reliable operation.

To share the store across projects, fend can mount a shared cache directory:

```
Host:  ~/.fend/cache/pnpm-store/  →  VM: /pnpm-store/

fend sets: PNPM_HOME=/pnpm-store
```

But this creates a second VirtioFS mount, and hard links between `/pnpm-store/` and `/workspace/node_modules/` would fail (cross-device). So pnpm falls back to copying, which is slower but functional.

### Recommended pnpm Configuration for Fend

```toml
# .fend.toml
[pnpm]
# Option A (default): store inside project, hard links work
store = "project-local"    # .pnpm-store in project dir, add to .gitignore

# Option B: shared store, copies instead of hard links
store = "shared"           # ~/.fend/cache/pnpm-store, uses copy fallback
```

### Does the Symlink Structure Work Over VirtioFS?

Yes. VirtioFS supports symlinks. pnpm's symlinked `node_modules/` structure (where `node_modules/react` is a symlink to `node_modules/.pnpm/react@18.2.0/node_modules/react`) works correctly over VirtioFS. The host IDE resolves these symlinks and TypeScript type resolution follows them correctly.

### Terminal Output

```
$ fend pnpm install
  fend: vm ready (0.8s)
  fend: pnpm store → project-local (.pnpm-store/)

  Packages: +387
  ++++++++++++++++++++++++++++++++++++++++++++

  Packages are hard linked from the content-addressable store to the
  virtual store at /workspace/node_modules/.pnpm.

  dependencies:
  + next 15.1.0
  + react 18.2.0
  + react-dom 18.2.0

  Done in 12.2s
```

### Performance Comparison

| Package Manager | Native | Fend (warm VM) | Notes |
|---|---|---|---|
| npm install | ~25s | ~28s | VirtioFS write overhead on 30k files |
| pnpm install (local store) | ~11s | ~13s | Hard links work, fewer file copies |
| pnpm install (shared store) | ~11s | ~16s | Falls back to copy, slower |
| bun install | ~5s | ~7s | Bun's speed advantage preserved |

---

## 8. Scenario 6: Shell Hook Mode

```bash
fend on
npm install       # automatically sandboxed
npm run dev       # automatically sandboxed
git status        # NOT sandboxed
fend off
```

### How It Works

`fend on` installs a shell hook (similar to nvm, direnv, or mise) that intercepts commands.

```
$ fend on
  fend: shell hook activated for ~/repos/my-app
  fend: sandboxing: npm, npx, node, pnpm, bun, yarn, deno, python, pip
  fend: passthrough: git, ls, cd, cat, vim, code, cursor
```

**Implementation (zsh):**

```zsh
# fend installs this hook via: eval "$(fend hook zsh)"

_fend_hook() {
  local cmd="$1"
  shift

  # Check if command should be sandboxed
  case "$cmd" in
    npm|npx|node|pnpm|bun|yarn|deno|python|python3|pip|pip3)
      # Route through fend
      command fend "$cmd" "$@"
      return $?
      ;;
    *)
      # Run natively
      command "$cmd" "$@"
      return $?
      ;;
  esac
}

# Override command_not_found_handler or use preexec
preexec() {
  # Parse the command line and potentially intercept
}
```

Actually, a cleaner approach uses shell aliases (simpler and more reliable):

```zsh
fend_on() {
  alias npm='fend npm'
  alias npx='fend npx'
  alias node='fend node'
  alias pnpm='fend pnpm'
  alias bun='fend bun'
  alias yarn='fend yarn'
  alias deno='fend deno'
  alias python='fend python'
  alias python3='fend python3'
  alias pip='fend pip'
  alias pip3='fend pip3'
  export FEND_ACTIVE=1
  echo "fend: shell hook activated"
}

fend_off() {
  unalias npm npx node pnpm bun yarn deno python python3 pip pip3 2>/dev/null
  unset FEND_ACTIVE
  echo "fend: shell hook deactivated"
}
```

### Terminal Experience

```
$ fend on
  fend: shell hook activated for ~/repos/my-app
  fend: commands routed through sandbox: npm npx node pnpm bun yarn

$ npm install                     ← transparently routed to fend
  fend: vm ready (0.8s)
  added 387 packages in 28s

$ npm run dev                     ← transparently routed to fend
  > next dev
  ▲ Next.js 15.1.0
  - Local: http://localhost:3000

$ git status                      ← runs natively, not sandboxed
  On branch main
  nothing to commit, working tree clean

$ code .                          ← runs natively
  (VS Code opens)

$ fend off
  fend: shell hook deactivated
```

### Auto-Activation via .fend.toml

If a project has a `.fend.toml` file, fend can auto-activate when you `cd` into the directory (like direnv's `.envrc`):

```toml
# ~/repos/my-app/.fend.toml
[hook]
auto = true        # auto-activate when entering this directory
sandbox = ["npm", "npx", "node", "pnpm"]  # customize which commands
passthrough = ["git", "ls", "cd"]          # explicit passthrough
```

```
$ cd ~/repos/my-app
  fend: auto-activated (from .fend.toml)

$ cd ~/repos/other-project
  fend: deactivated (left fend project)
```

This requires the direnv-style hook in `.zshrc`:

```zsh
eval "$(fend hook zsh)"
```

---

## 9. Key Architecture Decision: node_modules Location

This is the most consequential design decision in fend. Three options exist:

### Option A: On Host via VirtioFS (RECOMMENDED)

```
Host filesystem:        VM sees:
~/repos/my-app/         /workspace/
├── package.json        ├── package.json
├── node_modules/  ←──→ ├── node_modules/   (same files via VirtioFS)
├── src/                ├── src/
└── .fend.toml          └── .fend.toml
```

**Pros:**
- IDE works natively (TypeScript, ESLint, Prettier all resolve node_modules)
- No sync process, no stale data
- `git status` works naturally (node_modules in .gitignore)
- Familiar mental model: files are where you expect them
- No extra disk space

**Cons:**
- npm install is ~10-15% slower (VirtioFS write overhead for 30k files)
- Initial write of node_modules is the bottleneck

**Who does this:** Docker Desktop bind mounts, OrbStack bind mounts, Lima

**Research finding:** OrbStack achieves 88% of native speed for `pnpm install` with VirtioFS + caching. This is the acceptable tradeoff. Developers already tolerate similar overhead from antivirus scanning, Spotlight indexing, and Time Machine snapshots.

### Option B: VM-Only (In VM's ext4 Filesystem)

```
Host filesystem:        VM internal (ext4):
~/repos/my-app/         /vm-local/
├── package.json        └── node_modules/   (not visible on host)
├── src/
└── .fend.toml
```

**Pros:**
- npm install is native Linux speed (fastest possible)
- No VirtioFS overhead for writes

**Cons:**
- IDE cannot see node_modules: no TypeScript completions, no go-to-definition
- Need a separate mechanism (LSP proxy, file sync) to make IDE work
- Extra disk space (node_modules stored in VM disk image)
- Mental model breaks: "where are my node_modules?"

**Who does this:** Codespaces (with VS Code Remote), devcontainers with volume mounts

**Research finding:** VS Code's "Remote - Containers" extension solves the IDE problem by running extensions inside the container. But this requires a heavy VS Code extension, Cursor may not support it well, and non-VS Code editors (WebStorm, vim) get no intellisense at all. This is a non-starter for fend's "stay native" philosophy.

### Option C: Hybrid (VM-Local + Sync to Host)

```
Host filesystem:        VM internal (ext4):        Sync:
~/repos/my-app/         /vm-local/                 vm → host
├── package.json        └── node_modules/    ──→   ├── node_modules/
├── node_modules/ ←──── (synced copy)              │   (background sync)
├── src/
└── .fend.toml
```

**Pros:**
- Fast installs (native ext4 speed in VM)
- IDE works (synced copy on host)

**Cons:**
- Complexity: need a reliable, fast sync daemon
- Race conditions: what if IDE reads while sync is in progress?
- Double disk space
- Sync of 30k files takes time itself
- Which copy is authoritative? What about conflicts?

**Who does this:** Mutagen (used by Docker Desktop for a while, abandoned), some devcontainer setups

**Research finding:** Docker Desktop tried Mutagen-based sync for bind mounts and abandoned it in favor of VirtioFS. The sync approach adds complexity without sufficient benefit. OrbStack also chose VirtioFS over sync.

### Decision: Option A (Host via VirtioFS)

**Option A is the right choice for fend.** The rationale:

1. **IDE experience is non-negotiable.** Developers will not adopt a tool that breaks their editor. TypeScript completions, go-to-definition, and error checking must work without any setup.

2. **The performance overhead is acceptable.** 10-15% slower npm install is a minor cost. You run `npm install` a few times a day. You run the dev server for hours. The install overhead amortizes to nothing.

3. **Simplicity wins.** No sync daemon, no stale data, no "which copy is real" questions. The VirtioFS mount is the single source of truth.

4. **It's the direction the industry is moving.** Docker Desktop, OrbStack, and Lima all converged on VirtioFS. Apple's investment in VirtioFS performance (built into Virtualization.framework) means it will keep getting faster.

5. **Escape hatch exists.** For the rare user who needs maximum install speed, fend can offer a `--vm-local-modules` flag that uses Option B. But the default must be Option A.

---

## 10. Key Architecture Decision: File Watching & HMR

### The Problem

When a developer edits a file on the host (macOS), the change must propagate to the VM (Linux) so that the dev server (Next.js/Vite/webpack) can detect it and trigger HMR.

The chain: macOS FSEvents → VirtioFS → Linux inotify → chokidar/watchpack → bundler → WebSocket → browser.

### Current State of VirtioFS File Notifications

Based on research of Docker Desktop, OrbStack, Lima, and the VirtioFS kernel patches:

| Event Type | VirtioFS Support | Notes |
|---|---|---|
| MODIFY | Works reliably | File content changes propagate correctly |
| CREATE | Works reliably | New files detected |
| DELETE | Broken/Missing | Known gap in most VirtioFS implementations |
| RENAME | Partial | Some implementations miss the CREATE half |
| ATTRIB | Works | Permission/metadata changes |

For HMR, MODIFY is by far the most important event (editing existing source files). CREATE matters for new files/components. DELETE is rare in active development and usually requires a manual restart anyway.

### Fend's File Watching Strategy

A three-layer approach:

**Layer 1: Native VirtioFS inotify (default)**

VirtioFS propagates inotify events for MODIFY and CREATE. This handles 95% of HMR use cases. No extra configuration, no polling overhead.

**Layer 2: fendd fs-bridge daemon (enhancement)**

A lightweight daemon inside the VM that uses a secondary notification channel to cover gaps:

```
Host:                              VM:
┌──────────────┐                  ┌──────────────────┐
│ fend CLI     │                  │ fendd            │
│              │   vsock          │                  │
│ FSEvents ────┼──────────────→   │ fs-bridge        │
│ watcher on   │  FileChanged    │  ↓               │
│ project dir  │  messages       │ synthetic inotify │
│              │                  │ events on        │
│              │                  │ /workspace/      │
└──────────────┘                  └──────────────────┘
```

The host-side fend CLI watches the project directory using macOS FSEvents (which is reliable and efficient). When changes are detected, it sends `FileChanged` messages over vsock to fendd. fendd then generates synthetic inotify events on the VirtioFS mount point, ensuring the guest-side file watcher picks up the change.

This is the approach OrbStack uses (fsnotify-macvirt). It closes the DELETE event gap and ensures reliable notification across the VM boundary.

**Layer 3: Polling fallback (last resort)**

If layers 1 and 2 fail (unlikely), fend injects polling configuration:

```
CHOKIDAR_USEPOLLING=true
CHOKIDAR_INTERVAL=500
WATCHPACK_POLLING=true
```

This works universally but uses more CPU. Fend only activates this if the user explicitly enables it or if automatic detection determines that inotify events aren't propagating.

### Expected HMR Latency

| Setup | Edit-to-Render Latency |
|---|---|
| Native macOS | 100-300ms |
| Fend (VirtioFS inotify) | 200-500ms |
| Fend (fs-bridge) | 150-400ms |
| Fend (polling, 500ms) | 500-1000ms |
| Docker Desktop (VirtioFS) | 300-800ms |
| Docker Desktop (polling) | 1000-3000ms |

Fend's target with the fs-bridge layer is sub-500ms edit-to-render, which is imperceptible to most developers.

---

## 11. Key Architecture Decision: VirtioFS Performance

### Benchmark Expectations

Based on OrbStack's published benchmarks (the closest comparable system):

| Operation | Native macOS | VirtioFS (vanilla) | VirtioFS (with caching) |
|---|---|---|---|
| pnpm install | 10.9s | ~16s (est.) | 12.2s (88% native) |
| yarn install | 7.9s | ~14s (est.) | 9.8s (77% native) |
| rm -rf node_modules | 3.6s | ~7s (est.) | 4.0s (87% native) |
| Read 10k files | baseline | ~3x slower | ~1.5x slower |
| Write 10k files | baseline | ~3x slower | ~2x slower |
| Stat 30k files | baseline | ~3x slower | ~1.5x slower |

### Why "With Caching" Matters

OrbStack achieves near-native performance through a custom VirtioFS caching layer. The vanilla VirtioFS in Apple Virtualization.framework is approximately 3x slower than native for small-file I/O. With caching (metadata caching, readahead, write coalescing), this drops to 1.2-2x.

Fend should implement similar optimizations:

1. **VirtioFS cache policy: `always`** -- The VirtioFS FUSE cache policy can be set to "always" for aggressive metadata and data caching. This is safe for fend because only one VM accesses each project directory.

2. **Write coalescing** -- Batch small writes (common during npm install) into larger I/O operations.

3. **Readahead** -- Prefetch file content when directory listings are requested (anticipate that npm will read every package.json in node_modules).

### A Typical Next.js Project

| Metric | Value |
|---|---|
| node_modules file count | ~30,000 files |
| node_modules size | ~300-800MB |
| npm install time (native, empty cache) | ~20-30s |
| npm install time (native, warm cache) | ~5-10s |
| npm install time (fend, empty cache) | ~25-35s |
| npm install time (fend, warm cache) | ~7-12s |
| Dev server startup | ~2-4s |
| HMR latency (edit to render) | 200-500ms |

The overhead is concentrated in `npm install` (many small file writes). Once installed, dev server performance is CPU-bound (compilation) and the VirtioFS overhead is minimal because it's mostly reading files (which benefits from caching).

---

## 12. Architecture Diagrams

### Full System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                           macOS HOST                                 │
│                                                                      │
│  ┌────────────┐   ┌──────────────┐   ┌──────────────────────────┐   │
│  │ VS Code    │   │ Terminal     │   │ Browser                  │   │
│  │            │   │              │   │ http://localhost:3000     │   │
│  │ TypeScript │   │ $ fend npm   │   │                          │   │
│  │ resolution │   │   run dev   │   └───────────┬──────────────┘   │
│  │ works      │   │              │               │                  │
│  │ natively   │   └──────┬───────┘               │                  │
│  └─────┬──────┘          │                       │                  │
│        │                 │                       │                  │
│   reads from        ┌────┴──────────────────┐    │                  │
│        │            │    fend CLI            │    │                  │
│        │            │                       │    │                  │
│        │            │  - VM lifecycle mgmt   │    │                  │
│        │            │  - vsock gRPC client   │    │                  │
│        │            │  - FSEvents watcher   ◄────┤ port proxy       │
│        │            │  - Port proxy         ├────┘ localhost:3000   │
│        │            │  - Signal forwarding   │    → vsock → VM:3000 │
│        │            │  - Env var injection   │                      │
│        │            └───────────┬────────────┘                      │
│        │                        │ vsock                             │
│  ┌─────┴────────────────────────┼───────────────────────────────┐   │
│  │              VirtioFS        │                                │   │
│  │  ~/repos/my-app/ ←──────────►│/workspace/                    │   │
│  │  ~/.fend/cache/npm/ ←───────►│/root/.npm/                    │   │
│  │  ~/.fend/overlays/node-20/ ─►│/usr/local/ (read-only)        │   │
│  └──────────────────────────────┼───────────────────────────────┘   │
│                                 │                                   │
│  ┌──────────────────────────────┼───────────────────────────────┐   │
│  │  MICRO-VM (Apple Virtualization.framework)                    │   │
│  │  2 CPUs, 2GB RAM, custom arm64 Linux kernel                  │   │
│  │                              │                                │   │
│  │  ┌──────────────────────────┴────────────────────────────┐   │   │
│  │  │  fendd (PID 1)                                        │   │   │
│  │  │                                                       │   │   │
│  │  │  - gRPC server on vsock:1024                          │   │   │
│  │  │  - Process supervisor (fork/exec commands)            │   │   │
│  │  │  - Port detection (netlink socket monitoring)         │   │   │
│  │  │  - Signal relay (host SIGINT → child process)         │   │   │
│  │  │  - fs-bridge (vsock FileChanged → inotify events)     │   │   │
│  │  │  - stdout/stderr streaming back to host               │   │   │
│  │  │                                                       │   │   │
│  │  │  Child processes:                                     │   │   │
│  │  │    PID 42: npm run dev (next dev, listening :3000)    │   │   │
│  │  │    PID 87: npm test (jest)                            │   │   │
│  │  └───────────────────────────────────────────────────────┘   │   │
│  │                                                              │   │
│  │  Network: NAT via host (full internet access)                │   │
│  │  Filesystem: VirtioFS (project), ext4 (VM root)              │   │
│  │  No access to: ~/.ssh, ~/.aws, ~/Library, other projects     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Command Lifecycle (Detailed)

```
fend npm install
     │
     ▼
┌─────────────┐     ┌──────────────┐
│ Parse argv  │────►│ Resolve      │
│ cmd = npm   │     │ project dir  │
│ args = [    │     │ = cwd        │
│  install]   │     └──────┬───────┘
└─────────────┘            │
                           ▼
                  ┌────────────────┐
                  │ VM exists for  │──── Yes ──► Use existing VM
                  │ this project?  │             (warm path, ~5ms)
                  └────────┬───────┘
                           │ No
                           ▼
                  ┌────────────────┐
                  │ Read config    │
                  │ .fend.toml     │
                  │ package.json   │
                  │ .node-version  │
                  └────────┬───────┘
                           │
                           ▼
                  ┌────────────────┐
                  │ Boot VM        │
                  │ - Attach       │
                  │   VirtioFS     │
                  │ - Attach NAT   │
                  │ - Attach vsock │
                  │ - Boot kernel  │
                  │   (~800ms)     │
                  └────────┬───────┘
                           │
                           ▼
                  ┌────────────────┐
                  │ fendd READY    │
                  │ (over vsock)   │
                  └────────┬───────┘
                           │
                           ▼
                  ┌────────────────┐
                  │ Send           │
                  │ ExecuteCommand │
                  │ - cmd, args    │
                  │ - env vars     │
                  │ - cwd          │
                  │ - tty settings │
                  └────────┬───────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ fendd forks + execs    │
              │ npm install            │
              │                        │
              │ stdout ──→ vsock ──→   │──→ user terminal
              │ stderr ──→ vsock ──→   │──→ user terminal
              │                        │
              │ Exit code ──→ vsock ──→ │──→ fend CLI exit code
              └────────────────────────┘
                           │
                           ▼
                  ┌────────────────┐
                  │ VM stays warm  │
                  │ for next cmd   │
                  └────────────────┘
```

### Port Forwarding Flow

```
              Host                    VM
              ────                    ──

                              next dev starts
                              binds 0.0.0.0:3000
                                    │
                              fendd polls /proc/net/tcp
                              detects new LISTEN on :3000
                                    │
                              PortOpened{3000}
                              ────────────────────►
            fend CLI receives
            creates TCP listener
            on host localhost:3000
                    │
            Browser connects to
            localhost:3000
                    │
            TCP data ──────────────► vsock ──► VM:3000
                    ◄────────────── vsock ◄── VM:3000
            Response to browser

            When next dev stops:
                              PortClosed{3000}
                              ────────────────────►
            fend closes host
            listener on :3000
```

### HMR Data Flow

```
  Time     Host                     VM                      Browser
  ────     ────                     ──                      ───────

  T+0      User edits
           page.tsx in
           VS Code
           │
  T+1ms    macOS writes
           to disk
           │
  T+5ms    FSEvents fires   ──────► fs-bridge receives
           (fend CLI              synthetic inotify
            watcher)               event on /workspace/
           │                         │
  T+10ms   VirtioFS also ─────────► inotify fires
           propagates               (double-fire is
           (native path)            deduplicated by
                                    watchpack/chokidar)
                                     │
  T+15ms                            Turbopack/webpack
                                    detects change
                                    recompiles module
                                     │
  T+150ms                           Compilation done
                                    (~100-150ms)
                                     │
  T+155ms                           WebSocket push  ────────► HMR update
                                    (via port proxy)          received
                                                              │
  T+200ms                                                     React
                                                              re-renders
                                                              │
  T+250ms                                                     UI updated
                                                              on screen

  Total: ~250ms edit-to-render (vs ~150ms native)
```

---

## Summary of Key Decisions

| Decision | Choice | Rationale |
|---|---|---|
| node_modules location | Host via VirtioFS | IDE must work natively; 10-15% install overhead is acceptable |
| File watching | VirtioFS inotify + fs-bridge daemon | Covers 99% of cases; polling as last resort |
| VM per project | Yes, one VM per project directory | Isolation boundary matches project boundary |
| Multiple commands | Same VM, multiple processes | Simpler, lower resource usage, matches native behavior |
| Port forwarding | Automatic via netlink detection | Zero config for common case |
| npm cache | Host-side, mounted into VM | Shared across projects, survives VM restarts |
| pnpm store | Project-local by default | Avoids cross-device hard link failures |
| Shell hook | Alias-based interception | Simpler and more reliable than preexec hooks |
| Init system | Custom fendd (static binary) | Minimal, purpose-built, sub-200ms boot |
| Linux kernel | Custom config, VIRTIO built-in | Optimized for boot speed and VirtioFS performance |
| Env vars | Allowlist + explicit forwarding | Prevents accidental secret leakage |
| VM idle policy | Pause after 5min, stop after 30min | Balance between responsiveness and resources |

---

## Resolved Technical Decisions

1. **VM tech on macOS:** Apple Virtualization.framework directly (not Apple Containerization, which requires macOS 26). Supports macOS 13+. Code structured so Containerization can be adopted later.

2. **CLI language:** Swift for macOS CLI (native Virtualization.framework access). Rust for Windows/Linux CLI. Guest agent (fendd) is always Rust (cross-platform).

3. **Linux kernel:** Custom kernel config shipped with fend. Stripped drivers, VIRTIO compiled in, minimal modules. Essential for sub-second boot. Advanced users can supply their own kernel.

4. **VirtioFS cache:** `cache=always` policy, safe in fend's single-VM-per-project model. Additional caching optimizations (like OrbStack's approach) can be added if needed.

5. **Network policy:** Allow-all by default (least friction). Per-project network policy in `.fend.toml` for logging/blocking suspicious connections is a premium (macOS app) feature.
