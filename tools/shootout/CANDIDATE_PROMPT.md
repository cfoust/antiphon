# Candidate-agent prompt template

Give this to each exploration agent via the **Agent tool** with `isolation: "worktree"`. Replace
`<ID>` and `<HYPOTHESIS>`; everything else is verbatim. Launch all candidates in one message
(multiple Agent calls) so they run in parallel.

---

You are improving the **Antiphon** binaural renderer for a blind listening shootout. You are in an
isolated git worktree of the antiphon repo, branched off `research/shootout`. You will implement ONE
idea, render a fixed scene to a shared location, and commit. Another process (the supervisor)
loudness-matches all candidates and the human picks a winner by ear — so your job is a clean,
working, *different* render, not a finished feature.

GOAL: improve perceived fidelity with the **generic HRTF (NO personalization)**. The two problems
to attack (yours targets one; see your hypothesis): (1) a source directly ahead feels in-head /
slightly elevated and jumps ear-to-ear when the head turns; (2) the voice sounds like an electronic
speaker, not a real voice.

YOUR HYPOTHESIS — id `<ID>`: <HYPOTHESIS>

CONTRACT (follow exactly):

1. Orient first. Read `CLAUDE.md`, `docs/conventions.md`, and the signal flow in
   `crates/antiphon-dsp/src/lib.rs` (`Renderer::process`), plus whichever of
   `voice.rs` / `hrtf.rs` / `reverb.rs` / `dvf.rs` your idea touches. Do NOT guess at the
   coordinate/ITD conventions — they're pinned in `docs/conventions.md`.

2. Implement your ONE idea in `crates/antiphon-dsp` (the engine). Keep it self-contained and
   deterministic. Make it **ON by default** (you may add a parameter, but it must take effect with
   no extra flags, since the scene renders with stock settings). Do not change unrelated behavior,
   the shootout scene, `tools/shootout/*`, or anything in `out/`.

   **TUNE IT TO BE UNMISTAKABLY AUDIBLE.** This is a blind A/B with a single human listener — a
   change they cannot clearly hear is a *failed* candidate, even if it's "correct." Round 1 died of
   this: six tasteful, gentle tweaks were all indistinguishable from baseline; only the single
   boldest change (a whole-spectrum ±8 dB recolor) was perceptible and won. So: push your effect to
   the **strong end of plausible** — pick the loud, obvious version of your idea, not the polite one.
   Err toward *too much*; a winner can always be dialed back later, but an inaudible candidate
   teaches us nothing. Avoid only changes so extreme they're broken/unpleasant (harsh, clipping,
   obviously artifacted).

3. Build — this must succeed:
   `cargo build -p antiphon-render --release`

4. Render the fixed scene to the MAIN checkout's shared dir (both absolute paths so they resolve
   from your worktree):
   `cargo run -p antiphon-render --release -- shootout <repo>/assets/baked/antiphon-kemar.antiphon <repo>/out/shootout/<ID>.wav`

5. Sanity-check the printed peak: it must be finite, not silent, and not wildly clipping (roughly
   0.05–1.2). If it's broken (silent / NaN / runaway), fix your change — a broken render is useless
   and will be auto-rejected. **Also verify your change is audibly large:** the ingest step flags any
   candidate whose loudness-matched signal is within −45 dB RMS of baseline as "likely
   imperceptible." If you can cheaply estimate your delta (e.g. RMS of your render minus a baseline
   render, or just reason about the dB of change you applied), make sure it clears that bar. If your
   effect is marginal, turn it up before committing.

6. (LIVE RIG) Also build your change as a swappable wasm engine for the realtime, head-tracked A/B:
   `bash tools/shootout/build-live.sh <ID>` (emits `out/shootout/wasm/<ID>.wasm`). HARD RULE: do NOT
   change the `antiphon-ffi` C ABI (the exported `antiphon_*` function signatures) — every engine must
   be driven identically by the shared worklet. Edit `antiphon-dsp` internals only; your change must
   take effect with stock settings (ON by default, no new FFI flag needed for the A/B).

7. Commit your change on your branch with a clear message (so a winner's diff is recoverable).

8. Your FINAL MESSAGE is your report (it is not shown to a human directly — keep it factual). Return:
   - the id `<ID>`,
   - 2–3 sentences: exactly what you changed and the mechanism by which it should help,
   - the file(s)/function(s) you touched,
   - the printed peak from step 4,
   - any caveat (e.g. "may hurt side localization").
   Do NOT return the WAV — it's already at the shared path.

Constraints: only write `out/shootout/<ID>.wav` under `out/`. Do not modify the shootout scene,
`ingest.py`, or the ELO harness. Do not rebase or merge other branches. Stay within your one idea.
