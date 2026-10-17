# AGENTS.md

Guidance for anyone working on this repo: people and coding agents (Claude Code, Codex,
Copilot, Cursor, ...). Read it before changing code.

## What this is

macsh is a macOS (14+, Apple Silicon) menu-bar app that mounts remote storage as local
volumes without macFUSE. It wraps [rclone](https://rclone.org): for each remote it starts
`rclone serve webdav|nfs` on localhost and mounts that (WebDAV via NetFS, NFS via
`mount_nfs` under `~/macsh/<name>`). Backends today: SFTP, S3-compatible, FTP/FTPS,
WebDAV/Nextcloud, SMB and Google Drive (the generic `Backend.rclone` model; OAuth sign-in via
`OAuthAuthorizer`).

## Layout

- `Sources/MacshCore/` – all logic, no UI. Swift package (tools 5.9, links NetFS/Security).
  - `Models/` backend + remote models, `BackendDescriptor` (declarative backends)
  - `Rclone/` config builder, rclone process management
  - `Mount/` NetFS / `mount_nfs`; `Session/SessionManager` orchestrates mount/unmount
  - `Storage/` Keychain, `remotes.json`; `SSH/` host keys and key generation
  - `Update/` self-update: GitHub release lookup per channel, DMG download/verify/install
    (release asset names `macsh-*.dmg` / `macsh-lite-*.dmg` and nightly tags `nightly-YYYYMMDD-<sha>`
    are an interface; the app embeds its commit as `MacshBuildSHA`)
- `App/macsh/` – SwiftUI app, generated with xcodegen from `App/project.yml`
  (flavors `macsh` with bundled rclone and `macsh-lite`).
- `Tests/MacshCoreTests/` – unit and integration tests.
- `scripts/` – release build; `scripts/verify-dmg.sh` checks the built DMGs the way a user's Mac
  will (signature, layout, bundled rclone, Gatekeeper after a simulated download) and runs at
  the end of `build-release.sh`; `scripts/bench-mount.py` benchmarks a live mount (listing,
  upload and cold-read speed, measured on the wire with `nettop`); tests for both are in
  `scripts/tests/` (`python3 -m unittest discover -s scripts/tests`); `scripts/ci/` – servers
  used by the integration CI jobs.
- `.github/workflows/` – `ci.yml` (build, tests, coverage, integration, app compile), `release.yml`.

## Build and test

macOS only (Security, NetFS, SwiftUI); it does not compile on Linux.

```
swift build
swift test                       # unit tests; integration tests skip themselves
swift test --enable-code-coverage
```

Integration tests are gated by `MACSH_IT_*` environment variables and are normally run by
CI (see below). Do not commit changes you could not compile or test; if you work in an
environment without macOS, open a PR and let CI be the judge.

## Ways of working

- Develop on a branch, open a PR against `main` on this repo, and keep CI green.
  CI runs on every PR and on pushes to `main`.
- Every push to `main` publishes a `nightly-YYYYMMDD-<sha>` pre-release (`scripts/publish-nightly.sh`;
  only the newest kept, change history carried forward; one release per commit because immutable
  releases never allow a tag name to be reused). A `v*` tag publishes a
  release; the tag must match `CFBundleShortVersionString` in
  `App/macsh/Resources/Info.plist` and `Info-Lite.plist`.
- Update `CHANGELOG.md` (Keep a Changelog format, `[Unreleased]` section) for user-visible
  changes. Update the README when adding a backend.
- **Release notes are written for users first.** Tagged-release notes are built from the
  `CHANGELOG.md` section of the version (`scripts/release-body.sh`): "What's new" lists the
  features (Added, Changed) first, then the bugs fixed (Fixed), described by what the user gets or
  no longer suffers, not by how it was done. Internal work (CI, tests, scripts, refactors, build
  and release tooling) goes under `### For developers` in the same section, which the release
  page shows as a collapsed "For developers" block together with the commit list. Never put CI/CD
  or tooling items in Added/Changed/Fixed. Write the CHANGELOG section before tagging.
- Commit messages: short imperative subject, explain the why in the body.
- Keep changes focused; do not refactor unrelated code in a feature PR.

## Code conventions

- Secrets (passwords, keys, tokens) live in the Keychain and reach rclone only through
  `RCLONE_CONFIG_R_<OPTION>` environment variables. They must never be written to the
  temporary rclone config, `remotes.json`, logs or error messages.
- Anything that blocks (rclone start-up, host-key scan, NetFS, `mount_nfs`) runs off the
  main thread; only state changes and dialogs use it.
- New backends are declared as data: add a `BackendDescriptor` (fields, which are secret)
  rather than another `Backend` case plus `switch` arms. See `BackendDescriptor.webdav`.
- Existing `remotes.json` files and Keychain items must keep working: decode tolerantly and
  do not rename stored keys.
- Match the surrounding style, naming and comment density.

## Testing rules

1. **Unit tests for all new logic**, using the helpers in `Tests/MacshCoreTests/TestSupport.swift`
   (`FakeRclone`, `FakeMounter`, temp dirs). Fix tests you break; never skip or delete a
   test to get green.
2. **Every backend must be tested for real in the CI pipeline.** A backend is not done until a
   CI job starts a real server of that kind and an integration test drives macsh's own
   pipeline against it: `SessionManager.add` -> `mount` (real rclone, real `Mounter`) ->
   write a file through the mount -> verify it arrived on the server -> `unmount`. Cover
   both mount protocols (NFS and WebDAV) and every auth method the backend offers (e.g.
   password, key file, generated key). Do not bypass macsh by calling the rclone CLI.
   - Servers are started by scripts in `scripts/ci/` and exported as `MACSH_IT_*`
     variables. Docker/Podman cannot run on Apple Silicon runners (no nested
     virtualization), so run servers natively (PHP for Nextcloud, small Python servers,
     `rclone serve`, ...).
   - Use `IntegrationHarness.roundTrip` and `IntegrationEnv.require` from
     `IntegrationSupport.swift`; tests skip when their variables are unset.
   - Current coverage: SFTP, FTP, S3 (`BackendIntegrationTests`) and Nextcloud/WebDAV
     (`NextcloudIntegrationTests`), SMB (`BackendIntegrationTests`), Azure Blob against Azurite and the raw-options escape hatch (`AzureIntegrationTests`), plus Google Drive (`GoogleDriveIntegrationTests`, needs the
     `MACSH_IT_GDRIVE_TOKEN` repository secret; they skip without it). Backblaze B2 and Google Cloud Storage have no emulator and run only with test-account secrets (`NativeCloudAccountTests`). Known gaps: FTPS/TLS, passphrase-protected keys, real
     cloud providers (OAuth backends such as Google Drive will need a stand-in server or
     a test-account secret; document the choice in the PR).
3. **New code must be at least 80% covered.** CI fails a pull request when less than 80% of the
   changed lines under `Sources/` are covered by the unit tests (the `New-code coverage gate`
   step of `build-test`, using `diff-cover` on the llvm-cov report; the per-line report is in the
   job summary). Code in `App/` (SwiftUI) is not part of the package and is not measured, so keep
   logic in `MacshCore` and the views thin. Do not lower the threshold or exclude files to pass.
   Overall coverage of `MacshCore` is ~89% lines; do not let it drop.
4. Real-world checks that CI cannot do (Finder behaviour, a real provider account) are
   listed in the PR description as manual steps.

## Things to avoid

- Don't add dependencies without a reason; the core is dependency-free.
- Don't weaken host-key verification or certificate checks to make a test pass.
- Don't push tags or release from automation without the maintainer asking.
- Don't commit secrets, signing material or `.build/`.
