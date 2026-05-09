# Releasing Fend

This document describes the current manual release flow for the first public
alpha series.

## Release tag format

Use annotated tags in the form:

```bash
v0.1.0-alpha
```

Future pre-releases should follow the same pattern:

```bash
v0.1.1-alpha
v0.2.0-beta
```

## Before tagging

- Make sure the release branch is merged to `main`
- Confirm the working tree is clean
- Run the release-facing checks:

```bash
swift test --package-path swift
cargo test --manifest-path fendd/Cargo.toml
cargo test --manifest-path linux/Cargo.toml
./scripts/pack-npm.sh --platform linux-x64
./scripts/test-linux-npm-package.sh
```

- Review [CHANGELOG.md](../CHANGELOG.md) and move the release notes from
  `Unreleased` into the new version section if needed
- Confirm the README status text still matches reality

## Drafting release notes

- Start from the matching version entry in [CHANGELOG.md](../CHANGELOG.md)
- Keep the public notes concise:
  - what platforms are supported
  - what the headline features are
  - what remains explicitly alpha / not yet supported
- Link to the security policy and architecture docs where useful

## Signing and packaging

- Signed commits are required on the release branch and the final merge to
  `main`
- Build the npm payloads from a clean checkout
- macOS platform packaging is staged by `scripts/build-binary.sh`
- Linux x64 platform packaging is staged by `scripts/build-linux-binary.sh`
- Create tarballs with:

```bash
./scripts/pack-npm.sh --platform linux-x64
```

- Dry-run the publish flow before touching the registry:

```bash
./scripts/publish-npm.sh --platform linux-x64 --dry-run
```

## Notarization

The notarized macOS release flow is not finished yet.

Current status:

- The build script ad-hoc signs the macOS binary for local development
- Public releases still need proper Developer ID signing
- Public releases still need Apple notarization before the npm package should
  be announced broadly

Manual notarization remains a release blocker until that flow is documented and
repeatable.

## Publishing

Once the tarballs and signatures are ready:

1. Publish the platform package(s) first
2. Publish the root `@fendsh/cli` package second
3. Create the annotated git tag
4. Draft the GitHub release notes from [CHANGELOG.md](../CHANGELOG.md)
5. Attach any release artifacts if needed

## After release

- Verify `npm install -g @fendsh/cli` from a clean machine
- Verify `fend --version`
- Verify `fend doctor`
- Verify a real `fend npm install` run on macOS Apple Silicon
- Announce only after the install path, security policy links, and release
  notes all look correct
