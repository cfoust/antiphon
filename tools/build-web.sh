#!/usr/bin/env bash
# Build the wasm engine and stage it (with the asset) into web/ for serving.
set -euo pipefail
cd "$(dirname "$0")/.."

# +simd128 is harmless today (DSP is scalar) and ready for when we vectorize.
RUSTFLAGS="-C target-feature=+simd128" \
  cargo build -p chamber-ffi --release --target wasm32-unknown-unknown

cp target/wasm32-unknown-unknown/release/chamber_ffi.wasm web/chamber_ffi.wasm
cp assets/baked/chamber-default.chamber web/chamber-default.chamber

echo "staged web/chamber_ffi.wasm ($(du -h web/chamber_ffi.wasm | cut -f1)) + asset"
echo "serve with:  python3 -m http.server -d web 8080   (then open http://localhost:8080)"
