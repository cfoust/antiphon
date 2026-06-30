# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Chamber is a real-time, headphone binaural rendering engine: mono voices placed in 3D space,
head-tracked, with room acoustics. The defining constraint is **one Rust DSP core**
(`chamber-dsp`) exposed through **one C ABI** (`chamber-ffi`) that compiles to two targets and
drives two hosts:

- **Native macOS** — staticlib linked into a SwiftUI app (`native/ChamberApp`) via `AVAudioSourceNode`.
- **WebAssembly** — `wasm32` cdylib driven from an `AudioWorklet` (`web/`).

The two outputs are verified **byte-identical** (parity error ≈ −157 dBFS). Preserving this
parity is a hard invariant — see below.

## Architecture

```
crates/
  chamber-assets   .chamber binary format + zero-dep no_std reader. Defines the HRTF grid
                   direction convention (AssetBuilder::push_direction).
  chamber-dsp      the engine. NO I/O, NO threads, NO hot-path allocation. Owns the one
                   canonical coordinate frame. Modules: hrtf, reverb, voice, math.
  chamber-ffi      the SINGLE C-ABI surface for BOTH hosts (staticlib + wasm32 cdylib).
  chamber-bake     offline: analytic/SOFA HRTF model + room presets -> .chamber blob.
  chamber-render   offline: scene -> stereo WAV. Quality check AND the parity oracle.
native/ChamberApp  SwiftUI host. Vision-framework webcam head tracking -> head pose.
web/               Vite/Bun TS app + AudioWorklet (public/chamber-worklet.js) running the wasm.
```

Signal flow per source: minimum-phase HRIR FIR (128 taps, SIMD via `wide` f32x8) on the direct
path + separate fractional-delay ITD + distance/air-absorption → order-2 shoebox image-source
early reflections (per-surface 3-band absorption; the loudest images kept per source via an
energy-ranked, listener-independent top-K budget, 8 images/source) → late reverb (16-line FDN *or*
partitioned BRIR convolution, selectable per room preset). Coefficients ramp per block for
click-free motion.

### Invariants that are easy to break

- **Native↔wasm parity.** Any change in `chamber-dsp`/`chamber-ffi` must keep `node tools/parity.mjs`
  passing (error < −90 dBFS). Avoid platform-dependent float behavior, threading, and
  allocation on the audio path.
- **One coordinate frame.** `chamber-dsp` is the single source of truth (right-handed:
  +x right, +y up, +z back, front = −z; azimuth toward +left). Hosts convert at their edge.
  Read `docs/conventions.md` before touching anything geometry/ITD/pose related — the ITD sign
  and azimuth direction are pinned there and trivially flip left/right if you guess.
- **48 kHz everywhere.** HRIRs are baked at 48 k; the AudioContext is pinned to 48 k. The
  AudioWorklet quantum and recommended internal block is **128 frames**.

## Quality gate

There is no automated perceptual test — **evaluate audible changes by ear** using the offline
renders. After any DSP change, regenerate and listen to `out/*.wav` on headphones; keep
`chamber-render` working as the listening + parity oracle. A/B reverb backends by ear
(`hall` FDN vs `hall_conv` convolution).

## Common commands

```sh
# One-time: bake the HRTF + room asset (required before render/native/web).
cargo run -p chamber-bake --release -- assets/baked/chamber-default.chamber
# Measured SOFA instead of analytic: cargo run -p chamber-bake --release --features sofa -- <out> --sofa <file>

# Offline demos -> out/*.wav (listen on headphones).
cargo run -p chamber-render --release
# Other chamber-render subcommands: `parity`, `suite`, `voices`, `bench [asset]`.

cargo test --release

# Native macOS app: cargo staticlib -> swiftc link -> .app -> ad-hoc codesign (no Xcode/SwiftPM).
bash native/ChamberApp/make.sh && open native/ChamberApp/Chamber.app

# Web (wasm) app. build-web.sh rebuilds wasm + stages the best HRTF asset into web/public/.
bash tools/build-web.sh && python3 -m http.server -d web 8080
# Or from web/ with just: `just dev` (https, camera), `just harness` (test harness), `just wasm`.
```

### Parity test (run after any dsp/ffi change)

```sh
cargo run -p chamber-render --release -- parity              # writes native reference (out/parity_*.f32)
cargo build -p chamber-ffi --release --target wasm32-unknown-unknown
node tools/parity.mjs                                        # asserts native ≈ wasm < -90 dBFS
```

## Toolchain notes

- `rustup target add wasm32-unknown-unknown`. Web wasm is built with `RUSTFLAGS="-C target-feature=+simd128"`.
- Native app needs only Command Line Tools `swiftc` (no Xcode, no SwiftPM). If `swiftc` errors
  about a duplicate `SwiftBridging` module, disable the stale CLT modulemap once (see `docs/build.md`).
- `make.sh` bundles agent voice `.mp3`s from `$HOME/Developer/machinus/voice-chamber/public/audio`;
  if absent the app runs silent (HRTF/DSP still work).

## Key references

- `docs/conventions.md` — coordinate frame, azimuth direction, ITD sign, pose-from-tracker. Read first.
- `docs/build.md` — full build/toolchain details.
- `docs/web.md` — web app structure (worklet, `src/audio/`, bridge live mode).
- `docs/sofa.md` — measured SOFA importer (strict fidelity upgrade over the analytic placeholder).
- `web/justfile` — all web + live-mode (MCP/WebSocket/TTS bridge) recipes.
- The `scratch/` dir holds an earlier native spike; the live app is `native/ChamberApp`.
- `tools/shootout/SUPERVISOR.md` — (on the `research/shootout` branch) cold-start guide for the
  blind-ELO renderer-fidelity experiment: spawn candidate agents, loudness-match, A/B by ear.
