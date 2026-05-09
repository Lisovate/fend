# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0-alpha] - 2026-05-09

### Added

- First public alpha of Fend for macOS Apple Silicon
- Swift CLI and warm-VM daemon built on Apple's Virtualization.framework
- Rust guest agent (`fendd`) running as PID 1 inside the guest
- VirtioFS project directory sharing with host-to-guest port forwarding
- `fend <command>` sandboxing for `npm install`, dev scripts, tests, and other
  Node workflows
- Shell hook support for prefix-free sandboxed `npm`, `pnpm`, `bun`, `node`,
  and related commands
- `fend audit` with OSV-backed advisory checks, JSON output, and guided
  `--fix` flows

### Notes

- Linux x86_64 host work exists in-tree and is making progress, but it is not
  part of the released alpha support matrix yet
