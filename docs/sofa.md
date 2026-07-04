# Measured SOFA HRTF import — implemented

`antiphon-bake` can import a measured SOFA HRTF instead of the analytic model. The runtime
format (per-direction minimum-phase HRIR + ITD) is unchanged, so the engine and both hosts
are untouched — only the baker grows a SOFA path, behind the `sofa` cargo feature.

## Usage
```sh
# fetch a free dataset (MIT KEMAR dummy head)
bash tools/fetch-sofa.sh
# bake it (the `sofa` feature pulls in the pure-Rust `sofar` SOFA reader)
cargo run -p antiphon-bake --release --features sofa -- \
    assets/baked/antiphon-kemar.antiphon --sofa assets/sofa/mit_kemar_normal.sofa
# render demos with it
cargo run -p antiphon-render --release -- assets/baked/antiphon-kemar.antiphon out_kemar
```

## How it works (`bake_sofa`)
1. **Open + resample.** `sofar`'s `OpenOptions::new().sample_rate(48000.0).open(path)` reads
   the SOFA and resamples to 48 kHz on open (`sofar` 0.3 is pure Rust — no libmysofa C build,
   no cmake).
2. **Enumerate (default).** Read the set's own measurements at **full resolution** via
   `sofa.hrtf()` (`source_position`, `data_ir`, `m()/n()/r()`). Positions come back cartesian
   (`+x` front, `+y` left, `+z` up) → `az=atan2(y,x), el=atan2(z,hypot(x,y))`. `--sofa-grid`
   instead samples our fixed grid via the interpolating `sofa.filter(x,y,z,…)`.
3. **Minimum phase.** Each ear's measured IR → FFT magnitude (`mag_of_ir`) → the shared
   real-cepstrum routine (`min_phase_from_mag`, also used by the analytic model). This strips
   the bulk delay so neighbouring directions interpolate without comb-filtering.
4. **ITD.** Extracted from the raw IR onsets (−15 dB threshold, `onset_samples`) plus any
   stored per-ear delay, carried separately as fractional samples.

## Verified
- Coordinate mapping correct on both datasets: orbit ILD sweeps front→right(+9 dB)→left(−9 dB).
- **MIT KEMAR** (710 dirs, dummy head): stronger head-shadow ILD (~10 dB vs analytic ~5) and
  far more HF detail.
- **ARI nh2** (1550 dirs, real human, 48 k): strong elevation-dependent spectral cue (HF
  energy up=0.62 vs down=0.40) — the real-pinna front/back & elevation win the analytic model
  can't produce.
- **Performance:** the dense 1550-direction set costs only ~10% over the 296-dir analytic set
  (5.8× vs 6.5× realtime, 12 voices+order2+reverb) — the 3-nearest search is per-voice-per-
  block, not per-sample. A kd-tree would make it O(log n) if a much larger grid is ever used.

## Datasets
`tools/fetch-sofa.sh` grabs MIT KEMAR (dummy head) and ARI nh2 (dense, real human, 48 k) from
sofacoustics.org. Other free sets to try: **SADIE II** (KU100), **SONICOM**, FABIAN/FHK KU100.

## Notes / next
- Diffuse-field equalization, and per-dataset coordinate quirks, are worth a per-dataset
  sanity check (the orbit ILD sweep + elevation HF check are quick smoke tests).
- kd-tree the runtime nearest-search if a much larger grid is ever used (currently linear).

## Measured rooms (Tier-1 BRIR)
Drop a 48 kHz stereo `assets/brir/<room>.wav` and `antiphon-bake` uses it for that room's
convolution reverb (`load_brir_wav`). A BRIR-SOFA path (early/late split) is the next step.
