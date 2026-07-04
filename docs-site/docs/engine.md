---
id: engine
title: The engine
---

# The engine

Antiphon's renderer is a purpose-built binaural engine, not a game-audio middleware. The
design constraint that shaped everything: **one Rust DSP core, two hosts, byte-identical
output.**

## One core, two targets

The engine (`antiphon-dsp`) is a single Rust crate with no I/O, no threads, and no
allocation on the audio path. It's exposed through one C ABI (`antiphon-ffi`) that compiles
two ways:

- a **staticlib** linked into the native macOS app, pulled by an `AVAudioSourceNode`;
- a **wasm32 cdylib** driven from an `AudioWorklet` in the browser.

A parity harness renders the same scene through both and asserts the outputs match. They do
— to about −155 dBFS, which is to say: the web demo *is* the app's renderer.

## Signal path

Per voice, per 128-frame block at 48 kHz:

1. **HRTF convolution** — minimum-phase HRIRs (128 taps, SIMD), from the MIT KEMAR
   measured set, with a separate fractional-delay ITD line so interaural timing stays exact
   as you move your head.
2. **Distance** — level, air absorption, and near-field correction.
3. **Early reflections** — an order-2 shoebox image-source model with per-surface
   frequency-dependent absorption; the loudest images are kept per source under an
   energy-ranked budget.
4. **Late reverb** — either a 16-line feedback delay network or partitioned BRIR
   convolution, per room preset. The default room is a hall rendered by convolution.
5. **Head tracking** — the listener pose rotates the whole soundfield; coefficients ramp
   per block, so motion is click-free.

Voices can also carry a radiation pattern (a frequency-dependent cardioid, mirrored onto
reflections) and a volumetric extent (decorrelated satellite taps on a tetrahedron) — both
bit-exact no-ops when unused.

## Why head tracking matters

Static binaural audio tends to collapse to "in your head," especially for sources in front
of you. The strongest counter isn't a personalized HRTF — it's **motion**: when the world
counter-rotates against your head with low latency, your brain accepts the
externalization. That's why the app tracks your head with the webcam, and why the fit
slider (a simple frequency scale on the HRTF) is the only personalization knob: in
practice, tracking does the heavy lifting.

## Offline oracle

Everything audible ships through `antiphon-render`, an offline renderer that produces WAV
files from scene descriptions. It doubles as the quality gate (changes are evaluated by
ear, on headphones) and as the parity oracle. Even the soundtrack of the demo on the
marketing site is generated through it — the pitch is rendered by the product.
