#!/bin/bash
# Build SmartConnect.app for macOS.
#
#   ./macapp/build.sh            # build build/SmartConnect.app
#   ./macapp/build.sh --run      # build and launch it
#   ./macapp/build.sh --install  # copy to /Applications and launch it
#
# Requirements: Xcode Command Line Tools (swiftc) and a Rust toolchain. The webcam helper is built
# too when GStreamer is installed (`brew install gstreamer libnice-gstreamer`); without it the app
# is built without the webcam.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="SmartConnect"
BUNDLE_ID="app.smartconnect.mac"
VERSION="0.1.1"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
TARGET="arm64-apple-macosx13.0"

RUN=0
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --run) RUN=1 ;;
        --install) INSTALL=1; RUN=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v cargo >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
fi
command -v cargo >/dev/null || { echo "cargo not found (install Rust from https://rustup.rs)" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found (install Xcode Command Line Tools)" >&2; exit 1; }

mkdir -p "$BUILD_DIR"

WEBCAM=0
if command -v pkg-config >/dev/null && pkg-config --exists gstreamer-webrtc-1.0 gstreamer-sdp-1.0; then
    WEBCAM=1
fi

echo "==> building smartconnectd (release)"
cargo build --release -p smartconnect-mac
if [ "$WEBCAM" = 1 ]; then
    echo "==> building smartconnect-webcam (release)"
    cargo build --release -p smartconnect-webcam
else
    echo "==> skipping smartconnect-webcam: GStreamer not found (brew install gstreamer libnice-gstreamer)"
fi

echo "==> building Swift helper"
swiftc -O -swift-version 5 -target "$TARGET" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$ROOT/macapp/HelperInfo.plist" \
    -o "$BUILD_DIR/smartconnect-mac-helper" \
    macapp/SmartConnectHelper.swift

echo "==> building menu-bar app"
swiftc -parse-as-library -O -swift-version 5 -target "$TARGET" \
    -o "$BUILD_DIR/$APP_NAME" \
    macapp/SmartConnectApp.swift

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp target/release/smartconnectd "$APP/Contents/MacOS/smartconnectd"
[ "$WEBCAM" = 1 ] && cp target/release/smartconnect-webcam "$APP/Contents/MacOS/smartconnect-webcam"
cp "$BUILD_DIR/smartconnect-mac-helper" "$APP/Contents/MacOS/smartconnect-mac-helper"
chmod +x "$APP/Contents/MacOS/"*
cp macapp/Info.plist "$APP/Contents/Info.plist"
cp macapp/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing keeps macOS TCC and Gatekeeper happy for a local build. Sign nested executables
# first so the outer bundle's signature covers them.
echo "==> signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID.helper" "$APP/Contents/MacOS/smartconnect-mac-helper"
codesign --force --sign - --identifier "$BUNDLE_ID.daemon" "$APP/Contents/MacOS/smartconnectd"
if [ "$WEBCAM" = 1 ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID.webcam" "$APP/Contents/MacOS/smartconnect-webcam"
fi
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

# Refresh Launch Services so the icon and bundle id are picked up after rebuilding.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" >/dev/null 2>&1 || true

echo "built $APP"

if [ "$INSTALL" = 1 ]; then
    echo "==> installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
    APP="/Applications/$APP_NAME.app"
fi

if [ "$RUN" = 1 ]; then
    echo "==> launching $APP"
    open "$APP"
fi
