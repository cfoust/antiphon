#!/usr/bin/env bash
# Build the native macOS app: cargo staticlib -> swiftc link -> .app -> ad-hoc codesign.
# No Xcode / SwiftPM required (we link the Rust staticlib directly with swiftc -L/-l).
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

APP="native/ChamberApp/ChamberApp.app"
ASSET="assets/baked/chamber-default.chamber"
TARGET="arm64-apple-macos14.0"

echo "[1/4] cargo build staticlib"
cargo build -p chamber-ffi --release

echo "[2/4] bundle layout"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp native/ChamberApp/Info.plist "$APP/Contents/Info.plist"
[ -f "$ASSET" ] || ./target/release/chamber-bake "$ASSET" || { echo "bake the asset first"; exit 1; }
cp "$ASSET" "$APP/Contents/Resources/chamber-default.chamber"

echo "[3/4] swiftc compile + link"
export MACOSX_DEPLOYMENT_TARGET=14.0
swiftc -O -target "$TARGET" -parse-as-library \
  -import-objc-header native/CChamber/bridge.h -I native/CChamber \
  native/ChamberApp/Sources/*.swift \
  target/release/libchamber_ffi.a \
  -lc -lm \
  -framework AVFoundation -framework AppKit -framework Vision -framework CoreMedia \
  -o "$APP/Contents/MacOS/ChamberApp"

echo "[4/4] ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "built $APP"
echo "run:  open $APP        (grant camera access only if you toggle head-tracking)"
