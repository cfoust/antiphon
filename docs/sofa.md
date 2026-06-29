# Measured SOFA HRTF import — implemented

`chamber-bake` can import a measured SOFA HRTF instead of the analytic model. The runtime
format (per-direction minimum-phase HRIR + ITD) is unchanged, so the engine and both hosts
are untouched — only the baker grows a SOFA path, behind the `sofa` cargo feature.

## Usage
```sh
# fetch a free dataset (MIT KEMAR dummy head)
bash tools/fetch-sofa.sh
# bake it (the `sofa` feature pulls in the pure-Rust `sofar` SOFA reader)
cargo run -p chamber-bake --release --features sofa -- \
    assets/baked/chamber-kemar.chamber --sofa assets/sofa/mit_kemar_normal.sofa
# render demos with it
cargo run -p chamber-render --release -- assets/baked/chamber-kemar.chamber out_kemar
```

## How it works (`bake_hrtf_from_sofa`)
1. **Open + resample.** `sofar`'s `OpenOptions::new().sample_rate(48000.0).open(path)` reads
   the SOFA and resamples to 48 kHz on open (`sofar` 0.3 is pure Rust — no libmysofa C build,
   no cmake). MIT KEMAR's 512-tap @44.1 k IRs come back as 558-tap @48 k.
2. **Sample onto our grid.** For each (az, el) grid point we query the nearest measurement via
   `sofa.filter(x, y, z, &mut filter)` with **SOFA cartesian** coords (`+x` front, `+y` left,
   `+z` up): `x=cos(el)cos(az), y=cos(el)sin(az), z=sin(el)`. This reuses the existing grid +
   3-nearest runtime interpolation; no coordinate enumeration or triangulation needed.
3. **Minimum phase.** Each ear's measured IR → FFT magnitude (`mag_of_ir`) → the shared
   real-cepstrum routine (`min_phase_from_mag`, also used by the analytic model). This strips
   the bulk delay so neighbouring directions interpolate without comb-filtering.
4. **ITD.** Extracted from the raw IR onsets (−15 dB threshold, `onset_samples`) plus any
   stored per-ear delay (`filter.ldelay/rdelay`), carried separately as fractional samples.

## Verified
- Coordinate mapping correct: orbit ILD sweeps front→right(+10 dB)→left(−10 dB).
- Measured KEMAR has stronger head-shadow ILD (~10 dB vs the analytic ~5 dB) and far more
  high-frequency detail/presence (real pinna), which is the audible win for elevation and
  front/back.

## Notes / next
- Currently samples the SOFA at our fixed grid (nearest measurement). To preserve a dense
  set's full resolution, enumerate the file's own measurements instead and store them
  directly (the runtime interpolation already handles arbitrary grids).
- Diffuse-field equalization and per-dataset coordinate quirks (0–360 az, elevation sign) are
  worth a per-dataset sanity check.
- Other free 48 kHz sets to try: **SADIE II** (KU100), **SONICOM**, FABIAN/FHK KU100.

## Measured rooms (Tier-1 BRIR)
Drop a 48 kHz stereo `assets/brir/<room>.wav` and `chamber-bake` uses it for that room's
convolution reverb (`load_brir_wav`). A BRIR-SOFA path (early/late split) is the next step.
