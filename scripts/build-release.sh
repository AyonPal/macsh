#!/usr/bin/env bash
# Builds release-grade unsigned macsh.app and macsh-lite.app, then wraps
# each in a DMG suitable for uploading to a GitHub Release.
#
# Output: dist/macsh-<version>.dmg, dist/macsh-lite-<version>.dmg
#
# End users have to run this once after install to clear macOS's quarantine:
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
        build \
        | grep -E '(error:|warning:.*deprecated|BUILD SUCCEEDED|BUILD FAILED)' \
        || true
    if [[ ! -d "$PRODUCTS/$scheme.app" ]]; then
        echo "error: $PRODUCTS/$scheme.app not produced" >&2
        exit 1
    fi
}

make_dmg() {
    local scheme="$1"
    local app_path="$PRODUCTS/$scheme.app"
    local dmg_path="$DIST/${scheme}-${VERSION}.dmg"
    rm -f "$dmg_path"

    # Stage the .app + an Applications symlink so the DMG opens with a
    # familiar drag-to-install layout.
    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' RETURN
    cp -R "$app_path" "$stage/"
    ln -s /Applications "$stage/Applications"

    echo "==> hdiutil create $dmg_path"
    hdiutil create \
        -volname "$scheme" \
        -srcfolder "$stage" \
        -ov \
        -format UDZO \
        "$dmg_path" >/dev/null
}

build_target "macsh"
build_target "macsh-lite"

make_dmg "macsh"
make_dmg "macsh-lite"

echo
echo "Done. Outputs:"
ls -lh "$DIST"/*.dmg
