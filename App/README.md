# macsh app shell

The Swift sources for the macOS `.app` bundle live here. The Xcode project itself
(`macsh.xcodeproj`) is **not** committed — generate it on a Mac with the steps
below the first time you check out this repo.

There are **two app variants** that ship from one source tree:

| Variant      | Bundle ID         | rclone source                         | Best for                                 |
|--------------|-------------------|---------------------------------------|------------------------------------------|
| `macsh`      | `ai.macsh`        | bundled inside the `.app` (~50 MB)    | end users — zero setup, version pinned   |
| `macsh-lite` | `ai.macsh.lite`   | system: `brew install rclone` or PATH | developers / minimal-install lovers      |

Both share the exact same Swift code. The only differences are:
1. The `Copy Bundle Resources` build phase includes `rclone` for `macsh` and
   omits it for `macsh-lite`.
2. They use different `Info.plist` files (different `CFBundleIdentifier` /
   `CFBundleName`) so they can coexist on one Mac.

`RcloneBinary.resolve()` handles both: it tries `RCLONE_PATH` env first, then
the app bundle, then `/opt/homebrew/bin/rclone`, then `/usr/local/bin/rclone`.
The lite build naturally falls through to the Homebrew paths.

## First-time setup on a Mac

1. From the repo root:
   ```bash
   ./scripts/fetch-rclone.sh
   ```
   Downloads the arm64 `rclone` binary into `App/macsh/Resources/rclone`.
   (Skip if you only care about the lite variant — but harmless to run.)

   **Apple Silicon only.** In each Xcode target's Build Settings set:
   - `ARCHS = arm64`
   - `EXCLUDED_ARCHS[arch=x86_64] = x86_64`
   - `ONLY_ACTIVE_ARCH = NO` for Release

   so archives never produce an Intel slice.

2. Open Xcode → File → New → Project → macOS → App.
   - Product name: `macsh`
   - Team: your Developer ID
   - Interface: SwiftUI
   - Language: Swift
   - Save the `.xcodeproj` directly under `App/` (next to this README).
   - Delete the auto-generated `ContentView.swift` and `macshApp.swift`.

3. In the new project, drag in:
   - `App/macsh/MacshApp.swift`
   - `App/macsh/MenuBarController.swift`
   - all of `App/macsh/Views/*.swift`
   - `App/macsh/Resources/rclone` (target membership: `macsh`,
     "Copy Bundle Resources")
   - Replace the auto-generated `Info.plist` with `App/macsh/Resources/Info.plist`.
   - Set Code Signing Entitlements to `App/macsh/Resources/macsh.entitlements`.

4. Project settings → Package Dependencies → `+` → Add Local → select repo
   root. Add the `MacshCore` library to the `macsh` target.

5. ⌘R to run. Menu-bar item appears, no Dock icon.

## Adding the `macsh-lite` variant

After the steps above work, add a second target so both variants build from
the same project.

1. In Xcode, select the project → `+` (bottom of TARGETS list) → macOS → App.
   - Product name: `macsh-lite`
   - Same team, SwiftUI, Swift.
   - Xcode will scaffold a fresh source folder. Delete the auto-generated
     `ContentView.swift` and `macsh_liteApp.swift`.

2. Add the **same** existing files to this new target:
   - `App/macsh/MacshApp.swift`, `App/macsh/MenuBarController.swift`,
     and all `App/macsh/Views/*.swift` — select each in the navigator,
     show the File Inspector (⌥⌘1), tick the `macsh-lite` checkbox in
     "Target Membership". (Do NOT duplicate the files.)
   - Add the `MacshCore` package dependency to the `macsh-lite` target too
     (Project → Package Dependencies → click `MacshCore` → tick the
     `macsh-lite` target in the membership column).

3. Configure the lite target:
   - Build Settings → Info.plist File → set to
     `App/macsh/Resources/Info-Lite.plist`.
   - Signing & Capabilities → Code Signing Entitlements → set to
     `App/macsh/Resources/macsh.entitlements` (same as `macsh`).
   - Build Phases → "Copy Bundle Resources" — make sure `rclone` is **NOT**
     listed for this target. (It can stay listed for `macsh`.)

4. Pick the `macsh-lite` scheme from the toolbar and ⌘R. If `rclone` is on
   the system (e.g. `brew install rclone`), the app launches. If not, you
   get a critical alert telling you exactly how to install it.

After this, both schemes build independently. `Product → Archive` on each
gives you two separate `.app` bundles you can ship.

## What if someone runs `macsh-lite` without rclone installed?

`RcloneBinary.resolve()` throws `RcloneBinaryError.notFound`. The
AppDelegate catches this and shows a critical alert with installation
instructions:

> macsh failed to start
>
> rclone binary not found.
>
> Install with Homebrew:
>     brew install rclone
>
> Or download from https://rclone.org/downloads/
> and place the binary at one of:
>     /opt/homebrew/bin/rclone
>     /usr/local/bin/rclone
>
> Or set RCLONE_PATH in the environment to an explicit path.

Then the app quits cleanly. Re-launch after installing rclone.
