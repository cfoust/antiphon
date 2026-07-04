---
id: web-demo
title: The web demo
---

# The web demo

[antiphon.dev/demo.html](https://antiphon.dev/demo.html) is the full engine — the same Rust
DSP core compiled to WebAssembly, rendering the same room, with head tracking through your
browser's camera (MediaPipe instead of the native tracker). It is not a video and not an
approximation; native and wasm builds of the engine are verified byte-identical in CI-grade
parity tests.

What's different from the app:

- **The agents are scripted.** Four personas run through a plausible working session —
  tool ticks, murmurs, completions — instead of your real sessions.
- **No talk-back.** The reply flow needs a daemon on your machine.
- **Calibration is simplified**, though the hold-still onboarding is the same.

It's the honest way to evaluate the spatial rendering before installing anything: if voices
don't externalize for you on headphones, adjust the fit slider in onboarding — and if they
still don't, the app won't be different.

Chrome or Safari, headphones required, camera optional (you can decline tracking and steer
with the mouse instead).
