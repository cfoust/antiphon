# Chamber — a custom binaural rendering engine

Real-time, headphone binaural rendering of mono voices placed in 3D space, head-tracked,
with room acoustics. **One Rust DSP core** compiles to **native macOS** (linked into a Swift
app via a C ABI) and to **WebAssembly** (driven from an AudioWorklet) — verified
byte-identical across the two (parity error **−157 dBFS**).

Built on the conclusion that, for placing voices, the perceptual order is
**room > head-tracking > HRTF personalization > near-field**. So the engine does dynamic
per-source HRTF on the direct path, geometry-aware early reflections, and a parametric late
reverb — and defers personalization (hooks left in place).

## What works today
- **Direct path**: minimum-phase HRIR FIR (128 taps) + separate fractional-delay ITD +
  distance/air-absorption, with per-block coefficient ramping (click-free motion).
  3-nearest inverse-angle interpolation over a spherical grid.
- **Early reflections (Tier 2)**: first-order shoebox image sources rendered through the
  same HRTF kernel.
- **Late reverb**: 16-line FDN (Hadamard mixing, per-line damping, anti-denormal), RT60 from
  room geometry. (Convolution/BRIR backend — Tier 1 — is wired in the format/trait and is the
  next addition.)
- **Self-contained HRTF**: an analytic *structural* model (head-shadow ILD, elevation pinna
  notch, Woodworth ITD) baked offline → compact `.chamber` blob, so there are **zero external
  downloads** and the WASM runtime needs no SOFA/HDF5 parser. Swappable for measured SOFA.
- **Both hosts**: native `AVAudioSourceNode → Rust`, web `AudioWorklet → wasm`. 60 KB wasm,
  no imports, no SharedArrayBuffer.

## Layout
```
crates/
  chamber-assets   .chamber format + zero-dependency reader (no_std)
  chamber-dsp      the real-time engine (no I/O, no threads, no hot-path alloc) — native + wasm
  chamber-ffi      C ABI (staticlib for Swift; wasm32 cdylib for the worklet)
  chamber-bake     offline: HRTF model + rooms -> .chamber
  chamber-render   offline: scene -> stereo WAV (quality check + parity oracle)
native/ChamberApp  SwiftUI host (AVAudioSourceNode + Vision head tracking)
web/               index.html + AudioWorklet driving the wasm
tools/             build-web.sh, parity.mjs
docs/              conventions.md (coordinate frame), build.md
```

## Quickstart
```sh
cargo run -p chamber-bake   --release -- assets/baked/chamber-default.chamber
cargo run -p chamber-render --release            # listen to out/*.wav on headphones
bash native/ChamberApp/make.sh && open native/ChamberApp/ChamberApp.app
bash tools/build-web.sh && python3 -m http.server -d web 8080
```
See `docs/build.md`. Coordinate/ITD conventions: `docs/conventions.md`.

## Roadmap (next)
- Tier-1 convolution reverb from measured BRIRs (partitioned, `fft-convolver`) + a measured
  SOFA importer in `chamber-bake` (libmysofa via `sofar`, offline only).
- SIMD (`wide` / wasm `simd128`) on the FIR + FDN inner loops.
- Image-source order 2 with an energy-ranked global budget.
- 6DoF position from spatial face tracking; optional HRTF selection/personalization.
