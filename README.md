<div align="center">

# macsh

**Mount SFTP, S3, and FTP servers as native macOS volumes.**
No macFUSE. No kernel extensions. No security prompts.

[Download](https://github.com/AyonPal/macsh/releases) ·
[Install instructions](#install) ·
[Build from source](#build-from-source)

</div>

---

## What it does

Add a remote in a small form. Credentials go into your **Keychain**.
Finder, the Terminal, and any other app see a real `/Volumes/<name>`
local volume — exactly as if it were a USB drive.

```text
~ $ ls /Volumes/laptop
Documents/  Downloads/  Pictures/  ...
```

Behind the scenes macsh runs a private, localhost-only `rclone serve`
per active remote and asks Apple's `NetFS.framework` to mount it. macOS
treats the result as an ordinary network volume.

## Highlights

- **SFTP / SSH** — password, existing key file, or generate an ed25519 keypair in-app.
- **S3-compatible** — AWS, Cloudflare R2, Backblaze B2, Wasabi, MinIO, DigitalOcean Spaces, custom endpoints.
- **FTP / FTPS** — explicit or implicit TLS.
- **WebDAV or NFS** transport, per remote.
- **Live updates** — server-side changes appear in seconds, not minutes.
- **Auto-mount at login**, with exponential backoff on failure.
- **SSH host-key TOFU** with a fingerprint dialog on first connect.
- **Keychain-only secrets** — `remotes.json` never holds plaintext.
- **Crash-safe** — orphaned mounts from a previous instance heal automatically on next launch.

## Install

Releases are **unsigned** (no Apple Developer ID yet). Download the DMG
from the [latest release](https://github.com/AyonPal/macsh/releases),
drag the app to `/Applications`, then run **once**:

```bash
xattr -dr com.apple.quarantine /Applications/macsh.app
# or, for the lite variant:
xattr -dr com.apple.quarantine /Applications/macsh-lite.app
```

That clears macOS's Gatekeeper quarantine flag. Without it you'll see
*"macsh is damaged and can't be opened"* — that's Gatekeeper, not
actual corruption.

After that, launch the app. A small icon appears in your menu bar; click
it to add your first remote.

### Two flavours

|              | `macsh`                       | `macsh-lite`                 |
| ------------ | ----------------------------- | ---------------------------- |
| **DMG size** | ~32 MB                        | ~600 KB                      |
| **rclone**   | bundled inside the app        | uses your `brew install rclone` |
| **Best for** | "just works" install          | smaller download / power users |

The two coexist — different bundle IDs.

## Requirements

- macOS **14 (Sonoma)** or later
- Apple Silicon (M-series). Intel is not supported.

## Build from source

```bash
brew install xcodegen
git clone https://github.com/AyonPal/macsh.git
cd macsh
./scripts/fetch-rclone.sh         # arm64 rclone (only for the bundled variant)
swift test                        # unit tests
cd App && xcodegen generate       # produces App/macsh.xcodeproj
```

Open `App/macsh.xcodeproj`, pick the `macsh` or `macsh-lite` scheme, ⌘R.

To build a publishable DMG straight from the CLI:

```bash
./scripts/build-release.sh
# → dist/macsh-<version>.dmg
# → dist/macsh-lite-<version>.dmg
```

## Contributing

Bug reports and PRs welcome. Especially useful right now:

- Code signing / notarization (Apple Developer ID).
- NetFS-based NFS mount (currently still uses `mount_nfs`).
- Additional rclone backends behind the existing form abstraction.

## Acknowledgements

macsh is a thin Mac front-end over [rclone](https://rclone.org), which
does the network heavy lifting. Mounting goes through Apple's
`NetFS.framework`. UI is SwiftUI + AppKit.

## License

[Apache License 2.0](LICENSE) © 2026 Ayon Pal
