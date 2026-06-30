# Candidate-agent prompt template

Give this to each exploration agent via the **Agent tool** with `isolation: "worktree"`. Replace
`<ID>` and `<HYPOTHESIS>`; everything else is verbatim. Launch all candidates in one message
(multiple Agent calls) so they run in parallel.

---

You are improving the **Chamber** binaural renderer for a blind listening shootout. You are in an
isolated git worktree of the chamber repo, branched off `research/shootout`. You will implement ONE
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
   `crates/chamber-dsp/src/lib.rs` (`Renderer::process`), plus whichever of
   `voice.rs` / `hrtf.rs` / `reverb.rs` / `dvf.rs` your idea touches. Do NOT guess at the
   coordinate/ITD conventions — they're pinned in `docs/conventions.md`.

2. Implement your ONE idea in `crates/chamber-dsp` (the engine). Keep it self-contained and
   deterministic. Make it **ON by default** (you may add a parameter, but it must take effect with
   no extra flags, since the scene renders with stock settings). Do not change unrelated behavior,
   the shootout scene, `tools/shootout/*`, or anything in `out/`.

3. Build — this must succeed:
   `cargo build -p chamber-render --release`

4. Render the fixed scene to the MAIN checkout's shared dir (both absolute paths so they resolve
   from your worktree):
   `cargo run -p chamber-render --release -- shootout /Users/cfoust/Developer/cfoust/chamber/assets/baked/chamber-kemar.chamber /Users/cfoust/Developer/cfoust/chamber/out/shootout/<ID>.wav`

5. Sanity-check the printed peak: it must be finite, not silent, and not wildly clipping (roughly
   0.05–1.2). If it's broken (silent / NaN / runaway), fix your change — a broken render is useless
   and will be auto-rejected.

6. Commit your change on your branch with a clear message (so a winner's diff is recoverable).

7. Your FINAL MESSAGE is your report (it is not shown to a human directly — keep it factual). Return:
   - the id `<ID>`,
   - 2–3 sentences: exactly what you changed and the mechanism by which it should help,
   - the file(s)/function(s) you touched,
   - the printed peak from step 4,
   - any caveat (e.g. "may hurt side localization").
   Do NOT return the WAV — it's already at the shared path.

Constraints: only write `out/shootout/<ID>.wav` under `out/`. Do not modify the shootout scene,
`ingest.py`, or the ELO harness. Do not rebase or merge other branches. Stay within your one idea.
