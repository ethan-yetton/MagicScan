#!/bin/bash
set -euo pipefail

APP_NAME="MagicScan"
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS="$APP_DIR/Contents/MacOS"

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS"

swiftc \
    -parse-as-library \
    -O \
    -o "$MACOS/$APP_NAME" \
    "$ROOT/Sources/MagicScan.swift"

cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"

# Strip xattrs so codesign doesn't choke on resource forks.
xattr -cr "$APP_DIR"

# Ad-hoc sign so TCC can attach a stable identity to camera permission.
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
