<div align="center">

<img src="docs/icon.png" alt="macsh" width="128" height="128">

# macsh

**Mount SFTP, S3, FTP, WebDAV/Nextcloud servers and Google Drive as native macOS volumes.**
No macFUSE. No kernel extensions. No security prompts.

[Download](https://github.com/AyonPal/macsh/releases) ·
[Install](#install) ·
[Highlights](#highlights)

</div>

---

## What it does

<p align="center">
  <img src="docs/screenshot.png" alt="macsh — Add Remote form and menu bar dropdown" width="640">
</p>

Your remote files, in Finder. Open, edit, drag — like any folder on your Mac.

## Highlights

- **SFTP / SSH** — password, existing key file, or generate a new key in-app.
- **S3-compatible** — AWS, Cloudflare R2, Backblaze B2, Wasabi, MinIO, DigitalOcean Spaces, custom endpoints.
- **FTP / FTPS** — explicit or implicit TLS.
- **WebDAV / Nextcloud / ownCloud** — URL, user and (app) password.
- **SMB / Windows shares** — NAS, Samba and Windows shares by host, user, password and share name.
- **Azure Blob, Backblaze B2, Google Cloud Storage** — by account key / application key / service-account JSON; the container or bucket is the first path component.
- **Other rclone backend** — any rclone backend type with `name = value` options; secret options are kept in the Keychain, never in a file.
- **Google Drive** — browser sign-in; optional shared drive, root folder and your own OAuth client.
- **Live updates** — changes on the server show up in seconds.
- **Auto-mount at login.**
- **Passwords stored in your Keychain** — never on disk in plaintext.

## How it works

<p align="center">
  <img src="docs/architecture/architecture.png" alt="macsh architecture diagram" width="720">
</p>

## Install

Releases are **unsigned** (no Apple Developer ID yet). Pick one DMG from
the [latest release](https://github.com/AyonPal/macsh/releases) and drag
the app to `/Applications`.

The apps are signed ad hoc but not notarized (no Apple Developer ID), so the first launch
asks you to confirm: **right-click the app and choose Open**, or open *System Settings ->
Privacy & Security* and click **Open Anyway**. Or run the matching command **once** to clear
macOS's Gatekeeper flag:

```bash
# if you installed macsh
xattr -dr com.apple.quarantine /Applications/macsh.app

# if you installed macsh-lite
xattr -dr com.apple.quarantine /Applications/macsh-lite.app
```

If you see *"macsh is damaged and can't be opened"*, that's Gatekeeper rejecting an app whose
signature does not match its contents (older builds, before this was fixed), not corruption of
your download: the command above gets past it.

Launch the app. A small icon appears in your menu bar; click it to add
your first remote.

### Two flavours

|              | `macsh`                       | `macsh-lite`                 |
| ------------ | ----------------------------- | ---------------------------- |
| **DMG size** | ~32 MB                        | ~800 KB                      |
| **rclone**   | bundled inside the app        | uses your `brew install rclone` |
| **Best for** | "just works" install          | smaller download / power users |

Pick one. They can coexist if you want both.

## Requirements

- macOS **14 (Sonoma)** or later
- Apple Silicon (M-series). Intel is not supported.

## Contributing

Bug reports and PRs welcome. Especially useful right now:

- Code signing / notarization (Apple Developer ID).
- Additional backends.

## License

[Apache License 2.0](LICENSE) © 2026 Ayon Pal

## Updates

macsh checks GitHub for a new version about once a day and offers to install it
(Settings -> Updates, or "Check for updates..." in the menu). Choose **Stable releases**
(tagged `vX.Y.Z`) or **Nightly builds** (one per commit on `main`). The download is verified
against its published SHA-256, then the app is replaced in place and relaunched. macsh must be
installed in a folder you can write to (normally `/Applications`).
