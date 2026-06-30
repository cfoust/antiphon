#!/usr/bin/env bash
# Build the CURRENT checkout's engine as a swappable wasm for the live head-tracked A/B harness.
#
#   bash tools/shootout/build-live.sh <id>
#
# Compiles chamber-ffi to wasm32 (+simd128 — same artifact the parity check uses), drops it at
# out/shootout/wasm/<id>.wasm, and regenerates the live manifest (with loudness trims from the
# offline ingest). A candidate agent runs this from its own worktree to contribute an engine; the
# C ABI must stay identical across engines (edit chamber-dsp internals, not the chamber-ffi surface).
set -euo pipefail

ID="${1:?usage: build-live.sh <id>   (e.g. dfeq, baseline, dfeq_xfeed)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "building chamber-ffi wasm for engine '$ID'…"
RUSTFLAGS="-C target-feature=+simd128" \
  cargo build -p chamber-ffi --release --target wasm32-unknown-unknown

mkdir -p out/shootout/wasm
cp target/wasm32-unknown-unknown/release/chamber_ffi.wasm "out/shootout/wasm/$ID.wasm"
SZ=$(du -h "out/shootout/wasm/$ID.wasm" | cut -f1)
echo "  -> out/shootout/wasm/$ID.wasm ($SZ)"

uv run tools/shootout/live-manifest.py
echo "done. serve from repo root and open /tools/shootout/live/"
