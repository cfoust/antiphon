# Web interface (Bun + Vite)

The web app lives in `web/` and is the second primary Antiphon interface (with native macOS).
Both render through the **same Rust binaural engine** (`antiphon-ffi` → wasm) so they sound
identical: native links the staticlib; web runs the wasm in an AudioWorklet.

## Run
```sh
cd web
just install          # bun install
just dev              # builds wasm + serves the Antiphon app (https, camera works)
just sandbox          # THE dev tool: 3D scene editor over the engine (/sandbox.html)
```
`just wasm` rebuilds `web/public/antiphon_ffi.wasm` + stages the HRTF asset (run after any
`antiphon-dsp`/`antiphon-ffi` change).

## Pieces
- `public/antiphon-worklet.js` — the AudioWorklet running the wasm engine. Two source kinds:
  **live audio inputs** (Antiphon: one mono input per agent) and **buffer sources** (sandbox).
  Source struct is 10 floats: `x,y,z, gain, send, fx,fy,fz, directivity, extent`.
- `src/audio/wasmEngine.ts` — TS wrapper (pose, rooms, reflections, reverb blend, sources
  incl. facing/directivity/extent, live inputs, attention cue, immersion).
- `src/audio/engine.ts` — the Antiphon: same state machine / mix / radar as before, but the
  per-agent audio now sums into a wasm live-input instead of a `PannerNode`; HRTF + room
  reverb happen in the engine. `ENV_ROOM` maps env names → room presets.
- `sandbox.html` / `src/sandbox/` — the **sandbox** (replaces the old `test.html` harness,
  `arp-lab.html` and `attention-demo.html`): a three.js scene editor. Double-click the floor
  to add sources, drag to move, per-source volume/send/loop plus **directivity** (facing +
  amount, with an aim-at-listener shortcut) and **volumetric extent**; sounds are procedural
  SFX (`src/audio/sfx.ts`), the agent voices, uploaded audio files, or the **ARP synth**
  (`src/sandbox/arp.ts`, the agent-cue prototype with the full arp-lab parameter panel);
  room/reflections/FDN↔BRIR blend/master/HRTF-fit controls; the in-engine attention cue
  (agents + build time); webcam head tracking with eyes-open detection and an **immersion
  fade toggle (default off — manual immersion slider instead)**. Scenes autosave to
  localStorage and export/import as JSON.
- live mode (`/demo.html?live`) — connects to antiphond's /stream (the Go daemon
  replaced the old Bun bridge; see docs/internal/agent-bridge.md).

## Notes
- Single-threaded worklet → no SharedArrayBuffer / COOP-COEP headers needed.
- AudioContext is pinned to 48 kHz to match the baked HRTF asset.
- The Antiphon wasm path is new; verify the full experience by ear in a browser.
