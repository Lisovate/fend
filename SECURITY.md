# Security Policy

Fend is a security tool. If you believe you have found a vulnerability, please
report it privately first so we can investigate and coordinate a fix.

## Supported Versions

| Version | Supported |
| --- | --- |
| 0.1.x | ✅ |

## Reporting a Vulnerability

Preferred channel:

- Open a private report through [GitHub Security Advisories](https://github.com/Lisovate/fend/security/advisories/new).

Fallback channel:

- Email `security@<domain>`

<!-- TODO: replace security@<domain> with a real monitored security inbox before release. -->

Please include:

- A clear description of the issue and why it matters
- Reproduction steps or a proof of concept
- The affected version or commit
- Any suggested mitigations, if you have them

We will aim to:

- Acknowledge and triage new reports within 7 days
- Provide a fix or mitigation plan within 30 days for confirmed issues

## Scope

In scope:

- The Swift CLI in `swift/`
- The macOS daemon and VM lifecycle code in `swift/`
- The Rust guest agent in `fendd/`
- Install and packaging scripts in `scripts/`
- Runtime image preparation and build flows

Out of scope:

- Vulnerabilities that only exist in third-party dependencies and not in Fend's
  own integration or update process
- The host operating system, hypervisor implementation, or firmware
- A user's own project code, dependencies, install scripts, or dev server logic
  running inside the VM

If you are not sure whether something is in scope, send it anyway. We would
rather sort that out privately than have a security issue disclosed in public
before a mitigation exists.
