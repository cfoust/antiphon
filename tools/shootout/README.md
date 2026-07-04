# Renderer shootout — blind ELO

Explore renderer-fidelity improvements (with the **generic** HRTF — no personalization) by having
many agents each try one idea, then pick the winner by ear in a **blind, loudness-matched, ELO**
listening test. The baseline is always in the pool as the sanity floor.

## Pipeline

```sh
# 1. baseline (always) — and any candidate writes one WAV into out/shootout/
cargo run -p antiphon-render --release -- shootout assets/baked/antiphon-default.antiphon out/shootout/baseline.wav

# 2. sanitize (reject NaN/silent/clipped) + loudness-match to -23 LUFS -> out/shootout/norm/
uv run tools/shootout/ingest.py

# 3. listen: serve from the repo ROOT, open the harness
python3 -m http.server 8000
#   -> http://localhost:8000/tools/shootout/live/
```

In the harness: switch **A/B** (keys `a`/`b`), vote `1`/`2`/`3` (A / B / too-close), `space` plays.
Pairings are **ELO-guided** (least-played vs nearest-rated), so you don't do O(N²). Click
**standings** to peek at ratings, **export** to download the results JSON.

## Live, head-tracked A/B (`tools/shootout/live/`)

The offline A/B uses a fixed head, so it can only reward *timbre* — it's blind to dynamic
head-motion externalization. The live rig fixes that: each candidate also builds a wasm engine, and
the page hot-swaps between two engines in one AudioWorklet, both driven by your real head pose.

```sh
# each candidate emits a swappable engine (run from the candidate's checkout/worktree)
bash tools/shootout/build-live.sh <id>          # -> out/shootout/wasm/<id>.wasm  (+ regen manifest)
uv run tools/shootout/ingest.py                 # loudness trims (from the offline WAVs) into the manifest
# serve from repo ROOT, open the live harness (localhost is a secure context, so the camera works)
python3 -m http.server 8000   # -> http://localhost:8000/tools/shootout/live/
```

Press **start** (grants camera + audio), **set "forward"** while facing the screen, then move your
head — one voice stays fixed ~30° off-forward. `a`/`b` switch, `1`/`2`/`3` vote (blind, loudness-
matched, ELO-guided, click-free crossfade). Knobs: invert-yaw, source azimuth, room. Engines must
share the same `antiphon-ffi` C ABI (candidates edit `antiphon-dsp` internals only).

## The scene (`shootout` subcommand)

One voice (`tools/shootout/echo.wav`) tours the perceptually hard positions past a **fixed** head
(so externalization/front-back isn't rescued by head motion): a front arc back-and-forth, then a
full orbit with an elevation wobble (behind + angled + up). Same scene / signal / asset / room
(`room`, FDN) for every candidate — the renderer change is the only variable. It renders through
the **real `Renderer`**, so a candidate's `antiphon-dsp` edits show up.

## Candidate contract (for an exploration agent in its own worktree)

1. Implement **one** hypothesis in `antiphon-dsp` (the engine), keeping it deterministic.
2. `cargo build -p antiphon-render --release` must succeed.
3. Render to the **main checkout's** shared dir, using the main checkout's KEMAR asset (both
   absolute paths so it works from any worktree), naming the file after your idea:
   `cargo run -p antiphon-render --release -- shootout <repo>/assets/baked/antiphon-kemar.antiphon <repo>/out/shootout/<id>.wav`
4. Sanity-check the printed peak (roughly 0.05–1.2, not silent, finite).
5. Commit your change on your branch (so a winner's diff is recoverable).
6. Report: the id, what you changed and why, and the peak.

## Hypothesis deck (generic-HRTF fidelity levers — one per agent)

| id | idea |
|----|------|
| `decorr`     | subtle L/R decorrelation (short all-pass) for width / less in-head |
| `dfeq`       | diffuse-field EQ of the HRTF — kill the average "speaker" coloration |
| `fd_itd`     | frequency-dependent ITD (full at LF, less at HF) vs the broadband one |
| `crossfeed`  | mild low-passed crossfeed (classic headphone externalization) |
| `er_pattern` | denser/earlier first-order reflection pattern tuned for externalization |
| `front_notch`| sharpen the frontal pinna notch to disambiguate front-back |
| `near_pres`  | proximity/presence shaping for frontal sources |
| `rev_tilt`   | reverb spectral tilt + direct-to-reverberant ratio for distance |
| `hrir_smooth`| window/interpolation tweak to cut comb-filter "electronic" timbre |
| `lf_body`    | gentle LF body/chest shelf so a voice reads as a voice, not a speaker |
| `src_spread` | a couple of decorrelated near-copies to give the dry voice size |
| `air_damp`   | air-absorption + early-reflection HF damping naturalness |
