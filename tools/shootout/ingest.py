#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["soundfile", "pyloudnorm", "numpy"]
# ///
"""Sanitize + loudness-match shootout candidates so the blind ELO test measures *quality*, not
loudness (the one thing that silently ruins a single-listener A/B).

For every out/shootout/*.wav: reject broken renders (NaN/inf, silent, or wildly clipped), then
loudness-normalize to a fixed LUFS with a true-peak guard, and write out/shootout/norm/<name>.wav
plus a manifest.json the ELO harness loads.

Run: uv run tools/shootout/ingest.py
"""
import json
import os
import sys

import numpy as np
import pyloudnorm as pyln
import soundfile as sf

SRC = "out/shootout"
DST = "out/shootout/norm"
TARGET_LUFS = -23.0
PEAK_CEIL = 0.985
# Perceptibility gate: a candidate whose *loudness-matched* signal differs from baseline by less than
# this (RMS of the difference, in dB relative to baseline RMS) is unlikely to be told apart in a blind
# A/B — round 1 proved this (front_notch −55 dB and lf_body −51 dB were both inaudible ties). It's a
# warning, not a rejection: the render is fine, the *idea was tuned too gently*. Retune it louder.
PERCEPT_DB = -45.0

os.makedirs(DST, exist_ok=True)
files = sorted(f for f in os.listdir(SRC) if f.endswith(".wav"))

manifest = []
normed = {}  # name -> mono float array, for the perceptibility check below
for fn in files:
    path = os.path.join(SRC, fn)
    name = fn[:-4]
    data, rate = sf.read(path, always_2d=True)  # (n, ch)
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if not np.all(np.isfinite(data)):
        print(f"  REJECT {name}: non-finite samples"); continue
    if peak < 1e-4:
        print(f"  REJECT {name}: silent (peak {peak:.2e})"); continue
    if peak > 4.0:
        print(f"  REJECT {name}: runaway level (peak {peak:.2f})"); continue

    meter = pyln.Meter(rate)
    loud = meter.integrated_loudness(data)
    norm = pyln.normalize.loudness(data, loud, TARGET_LUFS)
    npeak = float(np.max(np.abs(norm)))
    if npeak > PEAK_CEIL:
        norm = norm * (PEAK_CEIL / npeak)  # peak guard (slight loudness give-up beats clipping)
    sf.write(os.path.join(DST, fn), norm, rate, subtype="PCM_16")
    manifest.append({"name": name, "file": fn})
    normed[name] = norm.mean(axis=1)  # mono mixdown for the delta metric
    print(f"  ok     {name:<22} in {loud:6.1f} LUFS -> {TARGET_LUFS} (peak {npeak:.2f})")

# Perceptibility gate vs baseline (after loudness-match, so it's a fair signal-shape comparison).
base = normed.get("baseline")
if base is not None:
    print("\nperceptibility vs baseline (RMS of difference; flagged if too small to likely hear):")
    base_rms = float(np.sqrt(np.mean(base ** 2))) + 1e-12
    for m in manifest:
        if m["name"] == "baseline":
            continue
        x = normed[m["name"]]
        n = min(len(x), len(base))
        d_rms = float(np.sqrt(np.mean((x[:n] - base[:n]) ** 2)))
        delta_db = 20.0 * np.log10(d_rms / base_rms) if d_rms > 0 else -np.inf
        m["delta_db"] = round(delta_db, 1)
        flag = "  <-- LIKELY IMPERCEPTIBLE; retune louder" if delta_db < PERCEPT_DB else ""
        print(f"  {m['name']:<22} {delta_db:6.1f} dB{flag}")
else:
    print("\n(no baseline.wav present — skipping perceptibility gate)")

manifest.sort(key=lambda m: (m["name"] != "baseline", m["name"]))  # baseline first
with open(os.path.join(DST, "manifest.json"), "w") as f:
    json.dump({"target_lufs": TARGET_LUFS, "candidates": manifest}, f, indent=2)
print(f"\n{len(manifest)} candidates -> {DST}/manifest.json", file=sys.stderr)
