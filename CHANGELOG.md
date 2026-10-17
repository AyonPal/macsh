# Changelog

All notable changes to macsh are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.4] — 2026-10-17

### Added

- **More places to mount.** WebDAV / Nextcloud / ownCloud, Google Drive (sign in through the
  browser; choose full, read-only or per-file access, a shared drive or root folder, or your
  own OAuth client), SMB / Windows shares (NAS, Samba), Azure Blob Storage, Backblaze B2 and
  Google Cloud Storage. Passwords and keys stay in the Keychain.
- **"Other rclone backend".** Mount any other rclone backend by typing its type and options;
  secret options are kept in the Keychain and never written to a file.
- **Test connection.** A button in the Add/Edit window checks your settings against the server
  (without saving or mounting) and explains failures: wrong password, host unreachable, folder
  or bucket not found, untrusted certificate.
- **Import from rclone.conf.** "Import from rclone…" in the menu reads your existing rclone
  config (SFTP, S3, FTP, WebDAV/Nextcloud, Google Drive, SMB) and stores the passwords in the
  Keychain. Unsupported types (crypt, alias, ...) are listed as such.
- **Read-only mounts** and an optional **bandwidth limit** per remote.
- **Updates from inside the app.** Settings → Updates lets you follow tagged releases or the
  nightly builds, and "Check for updates…" downloads, verifies and installs the new version
  and relaunches.
- **Google Drive and other cloud mounts browse much faster.** A Drive root listing went from
  43-47 s (and a timeout) to under 0.1 s. New per-remote settings: poll interval, prefetch,
  parallel read streams (off by default) and, for Google Drive, an opt-in for files flagged as
  malware.
- **Google client ID guidance** in the Drive form: an empty client ID uses rclone's shared,
  rate-limited client (being retired in 2026).

### Changed

- NFS mounts wait up to 60 s per request instead of 3 s, so slow servers no longer drop the
  mount.

### Fixed

- **"macsh is damaged and can't be opened" after installing.** The app's signature did not
  cover its own contents, so macOS rejected a downloaded copy. You now get the normal
  "unidentified developer" prompt (right-click → Open, or Privacy & Security → Open Anyway).
- **Stale NFS mounts.** A crashed rclone left its mount behind, so macOS showed "Server
  connections interrupted" and the next mount became `<name>-2`, `-3`, ... Leftovers are
  cleaned up at launch, an rclone that dies while mounted is detected (the remote is marked
  failed and retried if auto-mount is on), and quitting by signal now exits cleanly.
- **Google Drive stopped working an hour after "Sign in again".** Half-filled client
  credentials silently used rclone's shared client, whose token could not be refreshed. They
  are now refused, and changing the client ID requires signing in again.
- Deleting an S3 remote now also removes its Keychain items.

### For developers

- `scripts/verify-dmg.sh` checks a built DMG the way a user's Mac will (checksum, layout,
  version, arm64, signature, bundled rclone, Gatekeeper) and runs at the end of
  `build-release.sh`, so the release workflow fails on a bad DMG.
- `scripts/bench-mount.py` benchmarks a live mount (listing time, upload and cold-read speed).
- New rclone backends are declared as data (`BackendDescriptor`, stored as `Backend.rclone`)
  instead of new `switch` arms; `remotes.json` of existing remotes is unchanged.
- CI runs real servers (Nextcloud, SFTP, FTP, S3, SMB/Samba, Azure/Azurite) through macsh's
  own pipeline, compiles the app, and fails a PR with under 80% coverage of its new lines.
- Nightly builds publish again: each push to `main` makes one `nightly-YYYYMMDD-<sha>`
  pre-release (immutable releases forbid reusing a tag) and only the newest is kept.

## [0.1.3] — 2026-10-16

### Added

- **Per-remote performance settings.** Cache mode, read-ahead, buffer size,
  max cache size, directory-cache time and write-back delay can be tuned per
  remote and are validated before saving.
- **Faster NFS.** NFS remotes default to a full read cache with read-ahead and
  a 1s write-back (measured ~2.5 MB/s with `writes` vs ~17 MB/s).
- **GitHub Actions CI** (build, test, coverage report) and a **release
  workflow**: a `v*` tag publishes a release with DMGs and a commit list, and
  every push to `main` refreshes a rolling `nightly` pre-release whose notes
  keep a running change history.
- **Test coverage of `MacshCore` raised from ~13% to ~89%** (SessionManager,
  Mounter, RcloneProcess, HostKeyVerifier, config building and more).

### Changed

- NFS remotes now mount under `~/macsh/<name>` instead of the root-owned
  `/Volumes`.
- Mounting and unmounting no longer block the main thread, so the menu bar
  item stays responsive; a second mount request while one is in flight is
  ignored. rclone gets up to 30s to start listening and is cleaned up on
  failure.
- Editing an SFTP remote shows the saved key file path.

### Fixed

- The SFTP key passphrase is now passed to rclone.
- Mount errors are readable (with the tail of the rclone log) and key files
  are validated up front.
- Unmounting something already unmounted (ejected in Finder, rclone killed) is
  treated as success instead of an error.
- The whole Settings tab button is clickable, not just its label.

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
