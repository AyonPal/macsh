#!/usr/bin/env bash
# Downloads the latest arm64 (Apple Silicon) rclone macOS binary into
# App/macsh/Resources/rclone. Run from the repo root before opening the
# Xcode project (and in CI before xcodebuild archive).
#
# macsh ships Apple Silicon only — no Intel builds.
set -euo pipefail

cd "$(dirname "$0")/.."

DEST_DIR="App/macsh/Resources"
DEST="$DEST_DIR/rclone"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST_DIR"

echo "Fetching rclone for arm64..."
curl -fsSL -o "$TMP/arm64.zip" https://downloads.rclone.org/rclone-current-osx-arm64.zip
unzip -j -q "$TMP/arm64.zip" '*/rclone' -d "$TMP/arm64"

cp "$TMP/arm64/rclone" "$DEST"
chmod +x "$DEST"

echo "Done: $DEST"
file "$DEST" 2>/dev/null || true
