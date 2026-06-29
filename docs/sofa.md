# Baking a measured SOFA HRTF

Today `chamber-bake` synthesizes the HRTF from an analytic structural model. Swapping in a
**measured** SOFA set is a baker-only change — the runtime format (per-direction minimum-phase
HRIR + ITD) and the engine stay exactly as they are. Here's what it takes.

## The shape of the work

A SOFA file (AES69) is an HDF5/NetCDF container. For a `SimpleFreeFieldHRIR` set it holds:
- `Data.IR` — `[M measurements, R=2 receivers(ears), N taps]` raw (linear-phase) HRIRs
- `SourcePosition` — `[M, 3]` (azimuth°, elevation°, radius m)
- `Data.SamplingRate`

Baking = for each measurement, turn that raw HRIR pair into our `{min-phase L, min-phase R,
ITD}` and `push_direction(...)`. Concretely:

1. **Read the file (offline only).** Add the [`sofar`](https://docs.rs/sofar) crate (Rust
   bindings to libmysofa) to `chamber-bake` behind a `--sofa <file>` flag / cargo feature.
   libmysofa is C, so it needs `cc`/`clang` at build time — fine for the baker, and it never
   touches the runtime or the wasm build (which only read the baked blob).
2. **Resample to 48 kHz** if the set isn't already (SADIE II / SONICOM are 48 k; CIPIC is
   44.1 k). Use e.g. `rubato` offline.
3. **Map coordinates.** SOFA azimuth is CCW-from-front; ours is `az` toward +left (also CCW)
   — usually a straight `deg→rad`, but verify per dataset (some store 0–360, some elevation
   sign flipped). This is the single most error-prone step; sanity-check with a known
   front/right/left direction.
4. **Extract ITD** per direction (interaural cross-correlation of low-passed IRs, or a
   −10 dB onset-threshold delta between ears). Store as fractional samples — our format keeps
   ITD *separate* from the (min-phase) magnitude.
5. **Minimum-phase conversion.** Feed each ear's measured magnitude spectrum through the
   real-cepstrum routine **already in `chamber-bake`** (`min_phase_ear`'s cepstral block,
   factored out to take an arbitrary magnitude). This removes the bulk delay so neighboring
   directions interpolate without comb-filtering — which is why ITD is carried separately.
6. **Truncate/normalize** to 128 taps; optional diffuse-field equalization.
7. `push_direction(az, el, itd, &min_l, &min_r)` for every measurement. The runtime's
   3-nearest interpolation already handles arbitrary measurement grids — no triangulation
   needed (a precomputed triangulation is a later optimization for large grids).

## Effort

Roughly a day. The plumbing (format, min-phase, interpolation, both hosts) is done; the real
work is steps 3–5: coordinate matching, ITD estimation quality, and diffuse-field EQ.

## Free datasets to start with
- **SADIE II** (Bernschütz KU100 dummy head, 48 kHz) — small, high quality, permissive.
- **SONICOM** — large, modern, free for research.
- **CIPIC**, **ARI**, **MIT KEMAR** — classic references.

## Measured rooms (Tier-1 BRIR)
Two paths, both already wired at runtime:
- **Stereo WAV** — drop `assets/brir/<room>.wav` (48 kHz, 2 ch) and `chamber-bake` uses it
  (see `load_brir_wav`). Easiest for a measured binaural room IR.
- **BRIR SOFA** (`MultiSpeakerBRIR` / `SingleRoomDRIR`) — same libmysofa reader; extract the
  late portion for the diffuse reverb bus and (optionally) the early part for directional
  early reflections.
