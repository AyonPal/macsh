#!/usr/bin/env bash
# Regenerates the app icon (App/rmount/Resources/AppIcon.icns), docs/icon.png and the menu bar images
# (MenuBarIcon and MenuBarIconUploading, at 1x and 2x) from the drawing
# in scripts/make-icon.swift. macOS only (AppKit, iconutil).
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set_dir="$work/AppIcon.iconset"
mkdir -p "$set_dir"

draw() { swift scripts/make-icon.swift "$@"; }

# Draw each size directly; scaling a big bitmap down blurs the small ones.
for s in 16 32 64 128 256 512 1024; do draw "$s" "$work/$s.png"; done
cp "$work/16.png"   "$set_dir/icon_16x16.png"
cp "$work/32.png"   "$set_dir/icon_16x16@2x.png"
cp "$work/32.png"   "$set_dir/icon_32x32.png"
cp "$work/64.png"   "$set_dir/icon_32x32@2x.png"
cp "$work/128.png"  "$set_dir/icon_128x128.png"
cp "$work/256.png"  "$set_dir/icon_128x128@2x.png"
cp "$work/256.png"  "$set_dir/icon_256x256.png"
cp "$work/512.png"  "$set_dir/icon_256x256@2x.png"
cp "$work/512.png"  "$set_dir/icon_512x512.png"
cp "$work/1024.png" "$set_dir/icon_512x512@2x.png"

iconutil --convert icns "$set_dir" -o App/rmount/Resources/AppIcon.icns
cp "$work/256.png" docs/icon.png
# Menu bar template glyph, 18 pt at 1x and 2x.
draw 18 App/rmount/Resources/MenuBarIcon.png menubar
draw 36 App/rmount/Resources/MenuBarIcon@2x.png menubar
draw 18 App/rmount/Resources/MenuBarIconUploading.png menubar-uploading
draw 36 App/rmount/Resources/MenuBarIconUploading@2x.png menubar-uploading
echo "wrote AppIcon.icns, docs/icon.png and the MenuBarIcon images"
