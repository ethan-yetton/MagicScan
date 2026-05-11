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

# Prefer a stable self-signed identity so TCC permissions (Screen
# Recording, Camera) persist across rebuilds. Ad-hoc signing produces
# a new cdhash every build, which TCC treats as a different app and
# re-prompts. Fall back to ad-hoc if the cert hasn't been created yet.
SIGN_IDENTITY="MagicScan Dev"
if ! security find-identity -v -p codesigning | grep -q "\"$SIGN_IDENTITY\""; then
    echo "[warn] '$SIGN_IDENTITY' code-signing cert not found in login keychain."
    echo "[warn] Falling back to ad-hoc — Screen Recording permission will reset on every rebuild."
    echo "[warn] Create the cert in Keychain Access > Certificate Assistant > Create a Certificate."
    SIGN_IDENTITY="-"
fi

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

# Sign so TCC can attach a stable identity to camera + screen-capture
# permissions. With the self-signed cert the designated requirement
# is stable across builds; ad-hoc fallback regenerates per cdhash.
codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "Built $APP_DIR"

# Install to /Applications so LaunchServices indexes the bundle. Without
# this, the Screen Recording toggle in System Settings stays empty even
# though the TCC entry exists, because the Privacy UI joins TCC against
# LaunchServices and skips unregistered bundles.
INSTALL_DIR="/Applications/$APP_NAME.app"
rm -rf "$INSTALL_DIR"
cp -R "$APP_DIR" "$INSTALL_DIR"
# Re-sign in place so the cdhash matches the installed binary.
codesign --force --sign "$SIGN_IDENTITY" "$INSTALL_DIR"
# Nudge LaunchServices to pick it up immediately.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "$INSTALL_DIR" >/dev/null 2>&1 || true

# Symlink into the project tree so existing `open .../build/MagicScan.app`
# invocations keep working — point at the installed copy.
mkdir -p "$ROOT/build"
ln -sfn "$INSTALL_DIR" "$ROOT/build/$APP_NAME.app"

echo "Installed $INSTALL_DIR"
