# Changelog

All notable changes to macsh are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] — 2026-05-04

### Fixed

- **Crash-recovery: no more duplicate `/Volumes/<name>-1`, `<name>-2`
  pileups.** When macsh died ungracefully (SIGKILL, force-quit, crash),
  its child `rclone serve` process and the corresponding `/Volumes/`
  mount survived. On next launch, `autoMountAll` would mount again,
  and NetFS auto-numbered the colliding name. Each subsequent launch
  added another duplicate.

  Startup now reconciles: for each remote, parses `mount` output for an
  existing `/Volumes/<name>` mounted from `http://127.0.0.1:<port>/...`,
  unmounts it, and SIGTERMs the orphan rclone matched by `--addr` port.
  Per-port matching keeps it safe for `macsh-lite` users who may have
  unrelated rclone processes running.

  Verified end-to-end: launch → mount → `kill -9` → relaunch → single
  `/Volumes/<name>`, single rclone child.

## [0.1.0] — 2026-05-04

Initial public release.

### Added

- SFTP/SSH backend: password, existing key file, app-generated ed25519.
- S3-compatible backend: AWS, Cloudflare R2, Backblaze B2, Wasabi,
  MinIO, DigitalOcean Spaces, custom endpoint.
- FTP / FTPS backend: off / explicit / implicit TLS.
- WebDAV mount transport via Apple's `NetFS.framework`
  (`NetFSMountURLSync`). NFS mount transport via `/sbin/mount_nfs`.
  Per-remote toggle plus a global default in Settings.
- Live-updates toggle: when on, rclone serves with
  `--dir-cache-time 10s --vfs-fast-fingerprint` so server-side changes
  appear in ~10 seconds instead of rclone's 5-minute default.
- Edit existing remotes (disabled while mounted). Backend type is
  locked on edit; password fields stay blank with "leave blank to keep"
  semantics.
- Custom rclone path field in Settings — overrides the bundled binary
  for users who want to point at a specific install.
- Login items via `SMAppService.mainApp`. Auto-mount remotes flagged
  `autoMount=true` with exponential backoff (1s → 5s → 30s → 5min cap).
- Host-key TOFU: `ssh-keyscan` on first connect with fingerprint
  confirmation; loud blocking warning if a known key changes.
- Per-remote tailing log window.
- Two build variants from one source tree:
  - `macsh` — bundles `rclone` in `Resources/` (~32 MB DMG).
  - `macsh-lite` — uses `brew install rclone` or any PATH rclone (~600 KB DMG).
- `scripts/build-release.sh` produces both DMGs unsigned, ready to
  upload to GitHub Releases.

### Notes

- Apple Silicon only (arm64). Intel Macs not supported.
- macOS 14 (Sonoma) deployment target.
- Releases are unsigned. First-launch requires
  `xattr -dr com.apple.quarantine /Applications/macsh.app` to clear
  Gatekeeper. Notarized signing is a planned follow-up.

[0.1.1]: https://github.com/AyonPal/macsh/releases/tag/v0.1.1
[0.1.0]: https://github.com/AyonPal/macsh/releases/tag/v0.1.0
