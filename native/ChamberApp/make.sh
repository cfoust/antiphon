#!/usr/bin/env bash
# Build Chamber.app: cargo staticlib -> swiftc link -> .app -> ad-hoc codesign.
# No Xcode / SwiftPM required. Bundles the best available HRTF asset + the agent voices.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

APP="native/ChamberApp/Chamber.app"
TARGET="arm64-apple-macos14.0"
VOICES="$HOME/Developer/machinus/voice-chamber/public/audio"

echo "[1/5] cargo build staticlib"
cargo build -p chamber-ffi --release

echo "[2/5] choose HRTF asset"
# Prefer a measured set (neutral dummy head first), else the analytic default.
ASSET=""; HRTF=""
for cand in \
  "assets/baked/chamber-kemar.chamber:HRTF: MIT KEMAR (measured, dummy head)" \
  "assets/baked/chamber-ari.chamber:HRTF: ARI nh2 (measured, real human)" \
  "assets/baked/chamber-default.chamber:HRTF: analytic structural model"; do
  path="${cand%%:*}"; label="${cand#*:}"
  if [ -f "$path" ]; then ASSET="$path"; HRTF="$label"; break; fi
done
if [ -z "$ASSET" ]; then
  echo "  no asset found — baking analytic default"
  cargo run -q -p chamber-bake --release -- assets/baked/chamber-default.chamber
  ASSET="assets/baked/chamber-default.chamber"; HRTF="HRTF: analytic structural model"
fi
echo "  using $ASSET  ($HRTF)"

echo "[3/5] bundle layout + resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/audio"
cp native/ChamberApp/Info.plist "$APP/Contents/Info.plist"
cp "$ASSET" "$APP/Contents/Resources/chamber.chamber"
printf '%s' "$HRTF" > "$APP/Contents/Resources/hrtf.txt"
[ -f assets/audio/whisper.wav ] && cp assets/audio/whisper.wav "$APP/Contents/Resources/whisper.wav"  # attention-whisper prototype
if [ -d "$VOICES" ]; then
  cp "$VOICES"/*.mp3 "$APP/Contents/Resources/audio/" 2>/dev/null || true
  echo "  bundled $(ls "$APP/Contents/Resources/audio" | wc -l | tr -d ' ') voice files"
else
  echo "  WARNING: voices not found at $VOICES — the app will run silent"
fi

echo "[4/5] swiftc compile + link"
export MACOSX_DEPLOYMENT_TARGET=14.0
swiftc -O -target "$TARGET" -parse-as-library \
  -import-objc-header native/CChamber/bridge.h -I native/CChamber \
  native/ChamberApp/Sources/*.swift \
  target/release/libchamber_ffi.a \
  -lc -lm \
  -framework AVFoundation -framework AppKit -framework Vision -framework CoreMedia \
  -o "$APP/Contents/MacOS/Chamber"

echo "[5/5] ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "built $APP  ($HRTF)"
echo "run:  open $APP   (grant camera access; wear headphones)"
echo "note: ad-hoc signed — first launch may need right-click ▸ Open to bypass Gatekeeper."
