#!/usr/bin/env bash
# Build the wasm engine and stage it (+ the best HRTF asset) into web/public/ so the
# Vite app and the test harness can fetch /antiphon_ffi.wasm and /antiphon.antiphon.
set -euo pipefail
cd "$(dirname "$0")/.."

RUSTFLAGS="-C target-feature=+simd128" \
  cargo build -p antiphon-ffi --release --target wasm32-unknown-unknown

mkdir -p web/public
cp target/wasm32-unknown-unknown/release/antiphon_ffi.wasm web/public/antiphon_ffi.wasm

# prefer a measured HRTF (dummy head), else analytic default
ASSET=""
for c in antiphon-kemar antiphon-ari antiphon-default; do
  [ -f "assets/baked/$c.antiphon" ] && ASSET="assets/baked/$c.antiphon" && break
done
[ -z "$ASSET" ] && { cargo run -q -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon; ASSET="assets/baked/antiphon-default.antiphon"; }
cp "$ASSET" web/public/antiphon.antiphon

echo "staged web/public/antiphon_ffi.wasm ($(du -h web/public/antiphon_ffi.wasm | cut -f1)) + $ASSET"
