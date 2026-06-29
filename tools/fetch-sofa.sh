#!/usr/bin/env bash
# Fetch a free measured HRTF SOFA set for `chamber-bake --features sofa --sofa`.
# MIT KEMAR (dummy head) from sofacoustics.org — small, canonical, permissively licensed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/sofa
OUT=assets/sofa/mit_kemar_normal.sofa
URL="https://sofacoustics.org/data/database/mit/mit_kemar_normal_pinna.sofa"

if [ -f "$OUT" ]; then echo "have $OUT"; exit 0; fi
echo "downloading $URL"
curl -fL --max-time 120 -o "$OUT" "$URL"
sz=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")
echo "saved $OUT ($sz bytes)"
echo "bake:  cargo run -p chamber-bake --release --features sofa -- assets/baked/chamber-kemar.chamber --sofa $OUT"
