---
id: development
title: Development
---

# Development

The repo is a Cargo workspace plus three hosts. Everything below assumes a checkout of
[cfoust/antiphon](https://github.com/cfoust/antiphon).

## Layout

```
crates/
  antiphon-assets   .antiphon binary format + zero-dep no_std reader
  antiphon-dsp      the engine: HRTF, ITD, reflections, reverb (no I/O, no threads)
  antiphon-ffi      the single C ABI for both hosts (staticlib + wasm32 cdylib)
  antiphon-pose     6DoF head-pose solver (native tracker)
  antiphon-bake     offline: HRTF model + room presets -> .antiphon asset
  antiphon-render   offline: scene -> stereo WAV; the listening + parity oracle
native/AntiphonApp  SwiftUI host (swiftc only — no Xcode project)
antiphond/          Go daemon: agent registry, TTS ladder, WS hub
plugins/            per-agent adapters (claude-code, codex, opencode, pi, aider)
web/                marketing site + web demo (Vite/Bun + AudioWorklet)
docs/               this documentation (Docusaurus)
```

## Common tasks

Recipes live in the top-level `justfile`:

```bash
just bake     # one-time: bake the HRTF + room asset
just render   # offline demo renders -> out/*.wav (listen on headphones!)
just test     # cargo test --release
just parity   # native/wasm parity gate — run after ANY dsp/ffi change
just app      # build the native app (bundles antiphond)
just serve    # marketing site + web demo dev server
just tag      # ship a CalVer release tag
```

Toolchain: Rust stable with `wasm32-unknown-unknown`, Go ≥ 1.21, Xcode Command Line Tools,
[Bun](https://bun.sh), [just](https://github.com/casey/just), and `uv` for the Python
generator scripts.

## The two invariants

1. **Native↔wasm parity.** Any change to `antiphon-dsp` or `antiphon-ffi` must keep
   `just parity` passing (error < −90 dBFS; it sits around −155). Avoid
   platform-dependent float behavior, threading, and hot-path allocation.
2. **One coordinate frame.** The DSP crate owns geometry (right-handed, front = −z,
   azimuth toward +left). Hosts convert at their edge. The pinned facts (azimuth toward +left, the ITD sign)
   live in the repo's `CLAUDE.md` — they flip left/right if you guess.

## The quality gate is your ears

There is no automated perceptual test. After any audible change, regenerate the offline
renders and listen on headphones. If you can't hear the difference, that's a finding too —
say so in the PR.
