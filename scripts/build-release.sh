#!/usr/bin/env bash
# Builds release-grade unsigned macsh.app and macsh-lite.app, then wraps
# each in a DMG suitable for uploading to a GitHub Release.
#
# Output: dist/macsh-<version>.dmg, dist/macsh-lite-<version>.dmg
#
# The apps are ad-hoc signed (sealed) but not notarized, so on first launch users right-click >
# Open (or System Settings > Privacy & Security > Open Anyway), or clear the quarantine flag:
#   xattr -dr com.apple.quarantine /Applications/macsh.app
# (See README "Install" section.)

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
    exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found (Xcode missing or xcode-select misconfigured)." >&2
    exit 1
fi

# Version comes from the bundled-variant Info.plist. Bump CFBundleShortVersionString
# in both Info.plist files in lockstep before tagging a release.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/macsh/Resources/Info.plist)"
echo "Building macsh and macsh-lite v${VERSION} ..."

# Step 1: bundled rclone (only consumed by the `macsh` target; harmless for `macsh-lite`).
./scripts/fetch-rclone.sh

# Step 2: regenerate the Xcode project from project.yml.
( cd App && xcodegen generate )

# The commit this build comes from; the app uses it to tell which nightly it is running.
BUILD_SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo dev)}"

BUILD_DIR="App/build"
PRODUCTS="$BUILD_DIR/Build/Products/Release"
DIST="dist"
mkdir -p "$DIST"

build_target() {
    local scheme="$1"
    echo "==> xcodebuild ${scheme} (Release)"
    xcodebuild \
        -project App/macsh.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -derivedDataPath "$BUILD_DIR" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        MACSH_BUILD_SHA="$BUILD_SHA" \
        build \
        | grep -E '(error:|warning:.*deprecated|BUILD SUCCEEDED|BUILD FAILED)' \
        || true
    if [[ ! -d "$PRODUCTS/$scheme.app" ]]; then
        echo "error: $PRODUCTS/$scheme.app not produced" >&2
        exit 1
    fi
}

# xcodebuild runs with signing disabled, which leaves only the linker's ad-hoc stamp on the
# executable. That does not seal the bundle's resources (Info.plist, bundled rclone, icons), so
# on Apple Silicon a downloaded copy fails Gatekeeper's integrity check and macOS says
# "macsh is damaged and can't be opened". Seal the whole bundle with an ad-hoc signature
# (no Apple account needed); users then get the normal "unidentified developer" prompt.
seal_app() {
    local app_path="$1"
    echo "==> codesign (ad-hoc) $app_path"
    codesign --force --deep --sign - --entitlements App/macsh/Resources/macsh.entitlements "$app_path"
    codesign --verify --deep --strict "$app_path"
}

make_dmg() {
    local scheme="$1"
    local app_path="$PRODUCTS/$scheme.app"
    local dmg_path="$DIST/${scheme}-${VERSION}.dmg"
    rm -f "$dmg_path"
    seal_app "$app_path"

    # Stage the .app + an Applications symlink so the DMG opens with a
    # familiar drag-to-install layout.
    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' RETURN
    cp -R "$app_path" "$stage/"
    ln -s /Applications "$stage/Applications"

    # hdiutil's automatic size estimate can come up short on newer macOS and fail
    # with "No space left on device", so size the image explicitly (content + margin)
    # and use HFS+ for the temporary image.
    local size_mb
    size_mb="$(( $(du -sk "$stage/$scheme.app" | cut -f1) / 1024 + 64 ))"

    echo "==> hdiutil create $dmg_path (${size_mb} MB image)"
    hdiutil create \
        -volname "$scheme" \
        -srcfolder "$stage" \
        -ov \
        -fs HFS+ \
        -size "${size_mb}m" \
        -format UDZO \
        "$dmg_path" >/dev/null
}

build_target "macsh"
build_target "macsh-lite"

make_dmg "macsh"
make_dmg "macsh-lite"

echo
echo "==> verifying the DMGs"
./scripts/verify-dmg.sh "$DIST/macsh-${VERSION}.dmg" "$DIST/macsh-lite-${VERSION}.dmg"

echo
echo "Done. Outputs:"
ls -lh "$DIST"/*.dmg
