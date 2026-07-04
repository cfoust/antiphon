#!/usr/bin/env bash
# Build Antiphon.app: cargo staticlib -> swiftc link -> .app -> ad-hoc codesign.
# No Xcode / SwiftPM required. Bundles the best available HRTF asset + the agent voices.
set -euo pipefail
cd "$(dirname "$0")/../.."   # repo root

APP="native/AntiphonApp/Antiphon.app"
TARGET="arm64-apple-macos14.0"
VOICES="$HOME/Developer/machinus/voice-chamber/public/audio"

echo "[1/5] cargo build staticlib"
cargo build -p antiphon-ffi --release

echo "[2/5] choose HRTF asset"
# Prefer a measured set (neutral dummy head first), else the analytic default.
ASSET=""; HRTF=""
for cand in \
  "assets/baked/antiphon-kemar.antiphon:HRTF: MIT KEMAR (measured, dummy head)" \
  "assets/baked/antiphon-ari.antiphon:HRTF: ARI nh2 (measured, real human)" \
  "assets/baked/antiphon-default.antiphon:HRTF: analytic structural model"; do
  path="${cand%%:*}"; label="${cand#*:}"
  if [ -f "$path" ]; then ASSET="$path"; HRTF="$label"; break; fi
done
if [ -z "$ASSET" ]; then
  echo "  no asset found — baking analytic default"
  cargo run -q -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
  ASSET="assets/baked/antiphon-default.antiphon"; HRTF="HRTF: analytic structural model"
fi
echo "  using $ASSET  ($HRTF)"

echo "[3/5] bundle layout + resources"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/audio"
cp native/AntiphonApp/Info.plist "$APP/Contents/Info.plist"
cp native/AntiphonApp/Resources/Antiphon.icns "$APP/Contents/Resources/Antiphon.icns"
cp "$ASSET" "$APP/Contents/Resources/antiphon.antiphon"
printf '%s' "$HRTF" > "$APP/Contents/Resources/hrtf.txt"
# (whisper.wav prototype removed — the attention cue is now synthesized in-engine)
if [ -d "$VOICES" ]; then
  cp "$VOICES"/*.mp3 "$APP/Contents/Resources/audio/" 2>/dev/null || true
  echo "  bundled $(ls "$APP/Contents/Resources/audio" | wc -l | tr -d ' ') voice files"
else
  echo "  WARNING: voices not found at $VOICES — the app will run silent"
fi
# onboarding voice cues (calibration + fit), all UI languages — committed to the
# repo; regenerate with tools/gen-onboarding-voices.py
if [ -d native/AntiphonApp/Resources/onboarding ]; then
  mkdir -p "$APP/Contents/Resources/onboarding"
  cp native/AntiphonApp/Resources/onboarding/*.mp3 "$APP/Contents/Resources/onboarding/"
  echo "  bundled $(ls "$APP/Contents/Resources/onboarding" | wc -l | tr -d ' ') onboarding cues"
fi

echo "[3.5/5] antiphond (agent bridge daemon)"
if command -v go >/dev/null 2>&1; then
  (cd antiphond && go build -o "../$APP/Contents/MacOS/antiphond" ./cmd/antiphond)
  echo "  bundled antiphond (live agent bridge available)"
else
  echo "  WARNING: go not found — no antiphond; the app runs the canned demo only"
fi

echo "[4/5] swiftc compile + link"
export MACOSX_DEPLOYMENT_TARGET=14.0
swiftc -O -target "$TARGET" -parse-as-library \
  -import-objc-header native/CAntiphon/bridge.h -I native/CAntiphon \
  native/AntiphonApp/Sources/*.swift \
  target/release/libantiphon_ffi.a \
  -lc -lm \
  -framework AVFoundation -framework AppKit -framework Vision -framework CoreMedia \
  -o "$APP/Contents/MacOS/Antiphon"

echo "[5/5] ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "built $APP  ($HRTF)"
echo "run:  open $APP   (grant camera access; wear headphones)"
echo "note: ad-hoc signed — first launch may need right-click ▸ Open to bypass Gatekeeper."
