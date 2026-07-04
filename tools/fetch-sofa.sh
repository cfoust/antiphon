#!/usr/bin/env bash
# Fetch a free measured HRTF SOFA set for `antiphon-bake --features sofa --sofa`.
# MIT KEMAR (dummy head) from sofacoustics.org — small, canonical, permissively licensed.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p assets/sofa

# name|url pairs: MIT KEMAR (dummy head, sparse) and ARI nh2 (real human, dense, 48 k)
fetch() {
  local out="assets/sofa/$1" url="$2"
  if [ -f "$out" ]; then echo "have $out"; return; fi
  echo "downloading $out"
  curl -fL --max-time 180 -o "$out" "$url"
  echo "  saved $out ($(stat -f%z "$out" 2>/dev/null || stat -c%s "$out") bytes)"
}
fetch mit_kemar_normal.sofa "https://sofacoustics.org/data/database/mit/mit_kemar_normal_pinna.sofa"
fetch ari_nh2.sofa          "https://sofacoustics.org/data/database/ari/hrtf_nh2.sofa"

cat <<'EOF'
bake (enumerate, full resolution):
  cargo run -p antiphon-bake --release --features sofa -- \
      assets/baked/antiphon-ari.antiphon --sofa assets/sofa/ari_nh2.sofa
  cargo run -p antiphon-render --release -- assets/baked/antiphon-ari.antiphon out_ari
EOF
