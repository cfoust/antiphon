# Shootout supervisor — handoff / cold-start guide

You are the **supervisor** for a blind ELO listening experiment on the Chamber binaural renderer.
This file is written so a *fresh* Claude Code instance with no prior chat history can run the whole
thing. Read it top to bottom, then `tools/shootout/README.md` (the operational quick-ref) and
`tools/shootout/CANDIDATE_PROMPT.md` (the exact prompt you give each exploration agent).

## Mission

Find renderer changes that improve **perceived fidelity using the GENERIC HRTF — no
personalization** — and prove it by ear via a blind, loudness-matched, ELO A/B test. Two concrete
listener complaints drive this:

1. **Front collapse**: a source directly ahead sits *in-head / at the forehead, slightly elevated*,
   and **jumps ear-to-ear** when the head turns. (Sides localize fine; front is the dead zone —
   ITD/ILD ≈ 0 there, so only the (wrong, non-individual) pinna spectral cue is left.)
2. **"Electronic speaker" timbre**: the voice sounds like a small speaker in the room, not a real
   voice (coloration from the generic HRTF + no headphone EQ + comb-filtering).

Each **candidate** = ONE renderer hypothesis → one rendered WAV of a fixed scene. The human
listens A/B (blind, loudness-matched) until a clear winner emerges. The **baseline** (unmodified
renderer) is always in the pool as the sanity floor, so we never chase a direction that's just
worse-than-nothing.

## Project context (enough to be dangerous)

Chamber is a real-time binaural engine: one Rust DSP core (`crates/chamber-dsp`) behind one C ABI
(`crates/chamber-ffi`), compiled native (macOS app) and wasm (web). Signal flow per source:
direct-path min-phase HRIR FIR + separate fractional-delay ITD + near-field DVF → image-source
early reflections → late reverb (FDN or measured-BRIR convolution). Read `CLAUDE.md` and
`docs/conventions.md` first. The externalization work (head tracking, near-field DVF, 6DoF room
acoustics, and a frequency-scaling HRTF "fit" slider) is already on `main`. **This experiment is
about squeezing more fidelity WITHOUT requiring a personalized/measured HRTF.**

Hard invariant for production code is native↔wasm parity (`node tools/parity.mjs` < −90 dBFS) —
but **shootout candidates are offline experiments and do NOT need to hold parity.** They only need
to render the scene correctly.

## Current state (update this as you go)

- **Repo (main checkout):** `/Users/cfoust/Developer/cfoust/chamber`
- **Branch:** `research/shootout` (off `main`). Scaffolding is committed here.
- **Asset:** all candidates render on KEMAR via the main checkout's absolute path
  `/Users/cfoust/Developer/cfoust/chamber/assets/baked/chamber-kemar.chamber` (it's gitignored, so
  not in worktrees — the absolute path is how every worktree reaches it).
- **Seeded + validated:** `baseline` and `fit_1p5` (frequency-scale 1.5 via the `FREQ_SCALE` env
  hook) are rendered, ingested, and play in the harness.
- **Generated dirs (gitignored, regenerable):** `out/shootout/*.wav` (raw candidates),
  `out/shootout/norm/*.wav` + `manifest.json` (loudness-matched + the harness's input).

## The loop you run

1. **Choose hypotheses** — from the deck below, or invent new ones. Assign each a short `id`.
2. **Spawn one agent per hypothesis** using the **Agent tool** with `isolation: "worktree"` and
   `subagent_type: "general-purpose"` (or `claude`). Give each the contents of
   `CANDIDATE_PROMPT.md` with `<id>` and `<hypothesis>` filled in. Launch them in a single message
   (multiple Agent calls) so they run in parallel. Each agent works in its own worktree, renders to
   the shared `out/shootout/<id>.wav`, commits its diff, and returns a summary. Collect the
   summaries.
3. **Ingest:** `uv run tools/shootout/ingest.py` — rejects broken renders (NaN/silent/clipped),
   loudness-matches everything to −23 LUFS, rewrites `out/shootout/norm/manifest.json`. **This step
   is non-negotiable** — without it a single-listener A/B just measures loudness.
4. **Tell the human to listen:** from the repo root, `python3 -m http.server 8000`, open
   `http://localhost:8000/tools/shootout/elo/`. Keys: `a`/`b` switch, `1`/`2`/`3` vote
   (A / B / too-close), `space` plays. Pairing is ELO-guided (least-played vs nearest-rated) — no
   O(N²). "standings" reveals ratings; "export" downloads the results JSON.
5. **Read the result:** the human can hand you the exported `shootout_elo.json` (ratings + games +
   history) or just tell you the standings. Highest ELO well-separated from #2 = winner.
6. **Record the round in `tools/shootout/FINDINGS.md` — REQUIRED, every round.** Update the master
   ledger table (status, best ELO + Δ vs baseline, verdict, one-line finding) and add a dated round
   section from the template there: pool, comparison count, final standings, per-candidate listener
   notes, the outcome, and "deepen/revise" follow-ups (push new ideas into the Backlog). This is how
   the experiment compounds instead of re-trying the same things. Commit it.
7. **Iterate or promote:** spawn a round 2 (new hypotheses, refinements of the leader, or
   combinations of complementary winners — adding candidates keeps existing ELO and starts new ones
   at 1500), or promote a winner: review its `cand/<id>` branch diff and cherry-pick/merge into
   `main` after a parity check (`cargo run -p chamber-render --release -- parity` → wasm build →
   `node tools/parity.mjs`), re-tuning if the experimental change broke parity. Record the promotion
   in FINDINGS.md.

## Decisions already made (don't re-litigate)

- **Loudness-match is mandatory** (ingest does it). Louder ≠ better.
- **Blind + randomized A/B + ELO-guided** pairing (the human shouldn't know which file is which;
  we don't need every-vs-every).
- **Fixed head** in the scene — the hardest, most discriminating test; it's what exposes the front
  dead-zone. (A head-motion variant could be a future scene.)
- **KEMAR asset** — what the user actually listens on, so wins transfer to the app.
- **Generic HRTF only.** The whole point is improvements that need no ear scan / no personalization.

## The scene (don't change it mid-experiment — it must stay constant across candidates)

`chamber-render shootout <asset> <out.wav> [voice.wav]` (code in
`crates/chamber-render/src/main.rs`, `run_shootout`). One voice (`tools/shootout/echo.wav`) tours
the hard positions past a fixed head: front arc back-and-forth (0–6 s), then a full orbit with an
elevation wobble (6–12 s). Room = `room` (FDN). Renders through the real `Renderer`, so a
candidate's `chamber-dsp` edits take effect. Regenerate the baseline any time with:

```sh
cargo run -p chamber-render --release -- shootout \
  /Users/cfoust/Developer/cfoust/chamber/assets/baked/chamber-kemar.chamber \
  out/shootout/baseline.wav
```

## Hypothesis deck (generic-HRTF fidelity levers — one agent each)

| id | lever |
|----|------|
| `decorr`      | subtle L/R decorrelation (short all-pass) for width / less in-head |
| `dfeq`        | diffuse-field EQ of the HRTF — kill the average "speaker" coloration |
| `fd_itd`      | frequency-dependent ITD (full at LF, less at HF) vs the broadband one |
| `crossfeed`   | mild low-passed crossfeed (classic headphone externalization) |
| `er_pattern`  | denser/earlier first-order reflection pattern for externalization |
| `front_notch` | sharpen the frontal pinna notch to disambiguate front-back |
| `near_pres`   | proximity/presence shaping for frontal sources |
| `rev_tilt`    | reverb spectral tilt + direct-to-reverberant ratio for distance |
| `hrir_smooth` | window/interpolation tweak to cut comb-filter "electronic" timbre |
| `lf_body`     | gentle LF body/chest shelf so a voice reads as a voice, not a speaker |
| `src_spread`  | a couple of decorrelated near-copies to give the dry voice size |
| `air_damp`    | air-absorption + early-reflection HF damping naturalness |

The two complaints map most directly to: `dfeq`, `crossfeed`, `front_notch`, `lf_body`, `decorr`,
`hrir_smooth` — a good first six if you want to start focused.

## Files

- `tools/shootout/SUPERVISOR.md` — this file.
- `tools/shootout/CANDIDATE_PROMPT.md` — the exact prompt for each exploration agent.
- `tools/shootout/FINDINGS.md` — the running ledger; **update it after every round** (step 6).
- `tools/shootout/README.md` — operational quick-reference.
- `tools/shootout/ingest.py` — sanitize + loudness-match + manifest (uv inline deps).
- `tools/shootout/elo/index.html` — the blind ELO harness (served from repo root).
- `tools/shootout/echo.wav` — the committed source clip (reproducible across worktrees).
- `crates/chamber-render/src/main.rs` — the `shootout` subcommand (`run_shootout`).
