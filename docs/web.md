# Web interface (Bun + Vite)

The web app lives in `web/` and is the second primary Chamber interface (with native macOS).
Both render through the **same Rust binaural engine** (`chamber-ffi` → wasm) so they sound
identical: native links the staticlib; web runs the wasm in an AudioWorklet.

## Run
```sh
cd web
just install          # bun install
just dev              # builds wasm + serves the Chamber app (https, camera works)
just harness          # the renderer test harness — open the /test.html URL Vite prints
just harness-dev      # harness + the 3D dev head-view (CHAMBER_DEV=1)
```
`just wasm` rebuilds `web/public/chamber_ffi.wasm` + stages the HRTF asset (run after any
`chamber-dsp`/`chamber-ffi` change).

## Pieces
- `public/chamber-worklet.js` — the AudioWorklet running the wasm engine. Two source kinds:
  **live audio inputs** (Chamber: one mono input per agent) and **buffer sources** (harness).
- `src/audio/wasmEngine.ts` — TS wrapper (pose, rooms, reflections, sources, live inputs).
- `src/audio/engine.ts` — the Chamber: same state machine / mix / radar as before, but the
  per-agent audio now sums into a wasm live-input instead of a `PannerNode`; HRTF + room
  reverb happen in the engine. `ENV_ROOM` maps env names → room presets.
- `test.html` / `src/test.ts` — the **test harness**: click/drag to place sources, pick a
  procedural sci-fi SFX (`src/audio/sfx.ts`) or load a file, per-source volume, head yaw,
  room + reflections + master. The dev flag adds a 3D head-view.
- `bridge/` — the Bun MCP/WebSocket/TTS server for live mode (`just bridge`, `?live`).

## Notes
- Single-threaded worklet → no SharedArrayBuffer / COOP-COEP headers needed.
- AudioContext is pinned to 48 kHz to match the baked HRTF asset.
- The Chamber wasm path is new; verify the full experience by ear in a browser.
