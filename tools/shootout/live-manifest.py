#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = []
# ///
"""Build the LIVE harness manifest: list every engine .wasm in out/shootout/wasm/ and attach its
loudness trim (from the offline ingest manifest, which loudness-matched the same candidate to
-23 LUFS). The live harness applies that trim per engine so the realtime A/B measures rendering,
not loudness. Run after build-live.sh; baseline is listed first.

Run: uv run tools/shootout/live-manifest.py
"""
import json
import os
import sys

WASM = "out/shootout/wasm"
NORM = "out/shootout/norm/manifest.json"

trims = {}
try:
    for c in json.load(open(NORM)).get("candidates", []):
        trims[c["name"]] = c.get("trim", 1.0)
except FileNotFoundError:
    print("(no offline norm manifest — trims default to 1.0; run ingest.py for loudness match)", file=sys.stderr)

cands = []
for fn in sorted(os.listdir(WASM)):
    if not fn.endswith(".wasm"):
        continue
    name = fn[:-5]
    trim = trims.get(name, 1.0)
    entry = {"name": name, "file": fn, "trim": trim}
    # optional per-engine HRTF asset: a sidecar "<id>.asset" naming a file under assets/baked/
    # (used by HRTF-set candidates, e.g. hrtf_ari -> antiphon-ari.antiphon). Default is KEMAR.
    sidecar = os.path.join(WASM, name + ".asset")
    if os.path.exists(sidecar):
        entry["asset"] = open(sidecar).read().strip()
    cands.append(entry)
    flag = "" if name in trims else "  (no offline trim — render its WAV + ingest for loudness match)"
    asset = f"  asset={entry['asset']}" if "asset" in entry else ""
    print(f"  {name:<18} trim {trim:.3f}{asset}{flag}")

cands.sort(key=lambda c: (c["name"] != "baseline", c["name"]))  # baseline first
out = os.path.join(WASM, "manifest.json")
json.dump({"candidates": cands}, open(out, "w"), indent=2)
print(f"\n{len(cands)} engines -> {out}", file=sys.stderr)
