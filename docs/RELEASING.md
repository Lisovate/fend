# Releasing Fend

Pushing an annotated `v*` tag triggers `.github/workflows/release.yml`,
which builds the signed + notarized macOS arm64 and Linux x64 musl
binaries, publishes all three `@fendsh/*` npm packages with Sigstore
provenance, and creates the GitHub release. The manual flow below the
fold is the fallback when CI auth is unavailable or the workflow is
mid-fix.

## Release tag format

Use annotated tags in the form:

```bash
v0.1.0-alpha.1
v0.1.0-alpha.2
v0.2.0-beta.1
v1.0.0
```

The workflow assigns the npm dist-tag from the suffix:

| Tag suffix       | npm dist-tag |
|------------------|--------------|
| `-alpha`         | `alpha`      |
| `-beta`          | `beta`       |
| `-rc`            | `next`       |
| (no suffix)      | `latest`     |

During the alpha series the workflow also moves `latest` to each
new prerelease so `npm install -g @fendsh/cli` picks up the newest
alpha. This stops once a non-prerelease tag ships.

## Required GitHub secrets (one-time setup)

The workflow refuses to publish without these. Set them under
`Settings → Secrets → Actions`:

| Secret                                 | Source                                                                              |
|----------------------------------------|-------------------------------------------------------------------------------------|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64`   | `Keychain Access → right-click Developer ID Application cert → Export → .p12`, then `base64 -i cert.p12` |
| `APPLE_DEVELOPER_ID_CERT_P12_PASSWORD` | Password used during the P12 export                                                 |
| `APPLE_ID`                             | The Apple ID associated with the Developer ID cert                                  |
| `APPLE_TEAM_ID`                        | `487XSFNFDS`                                                                        |
| `APPLE_APP_SPECIFIC_PASSWORD`          | `appleid.apple.com → Sign-In and Security → App-Specific Passwords`                 |
| `NPM_TOKEN`                            | `npmjs.com → Access Tokens → Granular access`, publish scope on `@fendsh/*`         |

`NPM_TOKEN` must be an automation token so it bypasses 2FA in CI;
interactive WebAuthn / OTP login does not work inside GitHub Actions.

## Before tagging

- Make sure the release branch is merged to `main`
- Confirm the working tree is clean
- Run the release-facing checks:

```bash
./scripts/check-versions.sh                # every version source matches root package.json
swift test --package-path swift
cargo test --manifest-path fendd/Cargo.toml
cargo test --manifest-path linux/Cargo.toml
```

- On Linux you can stage a real npm payload locally:

```bash
./scripts/pack-npm.sh --platform linux-x64
./scripts/test-linux-npm-package.sh
```

  On macOS use the Docker variant — `scripts/build-linux-binary.sh`
  refuses to run on non-Linux hosts:

```bash
./scripts/build-linux-binary-docker.sh
```

- Review [CHANGELOG.md](../CHANGELOG.md) and move the release notes from
  `Unreleased` into the new version section if needed
- Confirm the README status text still matches reality

## Bumping the version

Every release touches at least these files. `check-versions.sh` is the
guard — it fails the PR if any drift:

- `package.json` (`version` and both `optionalDependencies` pins)
- `package-lock.json` (same fields)
- `packages/cli-darwin-arm64/package.json`
- `packages/cli-linux-x64/package.json`
- `linux/Cargo.toml` (and `linux/Cargo.lock` regenerates via `cargo check`)
- `swift/Sources/FendCLI/Fend.swift` (the hardcoded `version:` argument)
- `README.md` (the `fend --version` sample comment)

## Drafting release notes

- Start from the matching version entry in [CHANGELOG.md](../CHANGELOG.md)
- Keep the public notes concise:
  - what platforms are supported
  - what the headline features are
  - what remains explicitly alpha / not yet supported
- Link to the security policy and architecture docs where useful
- `release.yml` calls `gh release create --generate-notes` so the PR list
  since the previous tag is appended automatically — you only need to
  edit it if you want to lead with a narrative

## Manual fallback (workflow down)

If `release.yml` is broken or the secrets are not yet set, publish from
a clean checkout on Apple Silicon:

```bash
./scripts/build-binary.sh                  # signed + notarized macOS arm64
./scripts/build-linux-binary-docker.sh     # static-pie ELF host fend + aarch64-musl fendd

(cd packages/cli-darwin-arm64 && npm publish --access public --tag alpha)
(cd packages/cli-linux-x64    && npm publish --access public --tag alpha)
                                  npm publish --access public --tag alpha
```

Platform packages must publish first so the root's `optionalDependencies`
resolve cleanly. With WebAuthn 2FA each publish opens a browser auth
prompt — accept once and the session covers the remaining publishes.

After publishing manually, move `latest` so the README quickstart works:

```bash
npm dist-tag add @fendsh/cli@<version>                 latest
npm dist-tag add @fendsh/cli-darwin-arm64@<version>    latest
npm dist-tag add @fendsh/cli-linux-x64@<version>       latest
```

Then create the GitHub release the workflow would have created:

```bash
gh release create v<version> --prerelease --generate-notes
```

## After release

- Verify `npm install -g @fendsh/cli@<version>` from a clean machine
- Verify `fend --version` reports `<version>`
- Verify `fend doctor`
- Verify a real `fend npm install` run on macOS Apple Silicon
- Announce only after the install path, security policy links, and
  release notes all look correct
