# Antiphon — a custom binaural rendering engine

Real-time, headphone binaural rendering of mono voices placed in 3D space, head-tracked,
with room acoustics. **One Rust DSP core** compiles to **native macOS** (linked into a Swift
app via a C ABI) and to **WebAssembly** (driven from an AudioWorklet) — verified
byte-identical across the two (parity error **−157 dBFS**).

Built on the conclusion that, for placing voices, the perceptual order is
**room > head-tracking > HRTF personalization > near-field**. So the engine does dynamic
per-source HRTF on the direct path, geometry-aware early reflections, and a parametric late
reverb — and defers personalization (hooks left in place).

## What works today
- **Direct path**: minimum-phase HRIR FIR (128 taps, **SIMD** via `wide` f32x8) + separate
  fractional-delay ITD + distance/air-absorption, with per-block coefficient ramping
  (click-free motion). 3-nearest inverse-angle interpolation over a spherical grid.
- **6DoF**: full position + orientation pose; the engine recomputes per-source geometry from
  head position and orientation (see the `09_walk_6dof` demo and the native app's webcam
  position estimate).
- **Early reflections**: shoebox image sources up to **order 2**, rendered through the same
  HRTF kernel, capped by a **global energy-ranked budget** (48 voices) so CPU is bounded.
- **Late reverb, two backends**: parametric **16-line FDN** (Hadamard mix, per-line damping,
  anti-denormal) *and* **Tier-1 convolution** against a stereo BRIR (`fft-convolver`,
  partitioned). Selectable per room preset; A/B them by ear (`hall` vs `hall_conv`).
- **Self-contained HRTF**: an analytic *structural* model (head-shadow ILD, elevation pinna
  notch, Woodworth ITD) baked offline → compact `.antiphon` blob, so there are **zero external
  downloads** and the WASM runtime needs no SOFA/HDF5 parser. Swappable for measured SOFA
  (see `docs/sofa.md`). BRIRs can be dropped in as `assets/brir/<room>.wav`.
- **Both hosts**: native `AVAudioSourceNode → Rust`, web `AudioWorklet → wasm`. 60 KB wasm,
  no imports, no SharedArrayBuffer.
- **Performance**: ~6.5× realtime for 12 voices with order-2 reflections + reverb (release,
  one core); `cargo run -p antiphon-render --release -- bench`.

## Layout
```
crates/
  antiphon-assets   .antiphon format + zero-dependency reader (no_std)
  antiphon-dsp      the real-time engine (no I/O, no threads, no hot-path alloc) — native + wasm
  antiphon-ffi      C ABI (staticlib for Swift; wasm32 cdylib for the worklet)
  antiphon-bake     offline: HRTF model + rooms -> .antiphon
  antiphon-render   offline: scene -> stereo WAV (quality check + parity oracle)
native/AntiphonApp  SwiftUI host (AVAudioSourceNode + Vision head tracking)
web/               index.html + AudioWorklet driving the wasm
tools/             build-web.sh, parity.mjs
docs/              conventions.md (coordinate frame), build.md
```

## Quickstart
```sh
cargo run -p antiphon-bake   --release -- assets/baked/antiphon-default.antiphon
cargo run -p antiphon-render --release            # listen to out/*.wav on headphones
bash native/AntiphonApp/make.sh && open native/AntiphonApp/AntiphonApp.app
bash tools/build-web.sh && python3 -m http.server -d web 8080
```
See `docs/build.md`. Coordinate/ITD conventions: `docs/conventions.md`.

## Roadmap (next)
- ✅ **Measured SOFA importer** — `antiphon-bake --features sofa --sofa <file>` (pure-Rust
  `sofar` reader, resamples to 48 k, min-phase + ITD extraction). See `docs/sofa.md`. The
  measured set (e.g. MIT KEMAR) is a strict fidelity upgrade over the analytic placeholder.
- Enumerate a dense SOFA's own measurements (vs sampling our grid) to keep full resolution;
  diffuse-field EQ.
- Measured-BRIR rooms (drop-in `assets/brir/*.wav` already works; add BRIR-SOFA + early/late
  split for directional early reflections).
- SIMD on the FDN inner loop + wasm `simd128` tuning; non-uniform partitioned convolution.
- Near-field HRTF correction (<1 m); optional HRTF selection/personalization.
