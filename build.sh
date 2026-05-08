#!/bin/bash
set -euo pipefail

APP_NAME="MagicScan"
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Build outside the project (and outside iCloud-synced Documents) — the
# fileprovider daemon re-adds com.apple.FinderInfo to anything in iCloud
# between xattr -cr and codesign, which makes codesign fail.
BUILD_DIR="${TMPDIR:-/tmp}MagicScan-build"
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

# Symlink into the project tree so existing `open .../build/MagicScan.app`
# invocations keep working.
mkdir -p "$ROOT/build"
ln -sfn "$APP_DIR" "$ROOT/build/$APP_NAME.app"
