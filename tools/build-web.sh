#!/usr/bin/env bash
# Build the wasm engine and stage it (+ the best HRTF asset) into web/public/ so the
# Vite app and the test harness can fetch /chamber_ffi.wasm and /chamber.chamber.
set -euo pipefail
cd "$(dirname "$0")/.."

RUSTFLAGS="-C target-feature=+simd128" \
  cargo build -p chamber-ffi --release --target wasm32-unknown-unknown

mkdir -p web/public
cp target/wasm32-unknown-unknown/release/chamber_ffi.wasm web/public/chamber_ffi.wasm

# prefer a measured HRTF (dummy head), else analytic default
ASSET=""
for c in chamber-kemar chamber-ari chamber-default; do
  [ -f "assets/baked/$c.chamber" ] && ASSET="assets/baked/$c.chamber" && break
done
[ -z "$ASSET" ] && { cargo run -q -p chamber-bake --release -- assets/baked/chamber-default.chamber; ASSET="assets/baked/chamber-default.chamber"; }
cp "$ASSET" web/public/chamber.chamber

echo "staged web/public/chamber_ffi.wasm ($(du -h web/public/chamber_ffi.wasm | cut -f1)) + $ASSET"
