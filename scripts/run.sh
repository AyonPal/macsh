#!/usr/bin/env bash
# Builds macsh in Debug configuration and launches it.
# Usage: ./scripts/run.sh [--release]

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

CONFIGURATION="Debug"
if [[ "${1:-}" == "--release" ]]; then
    CONFIGURATION="Release"
fi

( cd App && xcodegen generate --quiet )

BUILD_DIR="App/build"
PRODUCTS="$BUILD_DIR/Build/Products/$CONFIGURATION"

echo "==> Building macsh ($CONFIGURATION)..."
xcodebuild \
    -project App/macsh.xcodeproj \
    -scheme macsh \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    build \
    | grep -E '(error:|warning:.*deprecated|BUILD SUCCEEDED|BUILD FAILED)' \
    || true

APP="$PRODUCTS/macsh.app"
if [[ ! -d "$APP" ]]; then
    echo "error: $APP not produced" >&2
    exit 1
fi

# Kill any running instance before launching the fresh build.
pkill -x macsh 2>/dev/null || true

echo "==> Launching $APP"
open "$APP"
