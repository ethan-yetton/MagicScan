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

# Install to /Applications so LaunchServices indexes the bundle. Without
# this, the Screen Recording toggle in System Settings stays empty even
# though the TCC entry exists, because the Privacy UI joins TCC against
# LaunchServices and skips unregistered bundles.
INSTALL_DIR="/Applications/$APP_NAME.app"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
# Re-sign in place so the cdhash matches the installed binary.
codesign --force --sign - "$INSTALL_DIR"
# Nudge LaunchServices to pick it up immediately.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$INSTALL_DIR" >/dev/null 2>&1 || true

# Symlink into the project tree so existing `open .../build/MagicScan.app`
# invocations keep working — point at the installed copy.
mkdir -p "$ROOT/build"
ln -sfn "$INSTALL_DIR" "$ROOT/build/$APP_NAME.app"

echo "Installed $INSTALL_DIR"
