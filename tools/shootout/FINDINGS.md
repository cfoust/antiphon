# Shootout findings ledger

A running record of every hypothesis tried, how it performed (blind ELO + listener notes), a
quality verdict, and where to deepen. **The supervisor MUST update this after each round** — it's
how the experiment accumulates knowledge instead of re-trying the same things. Keep entries terse
and factual; this is a lab notebook, not prose.

## Legend

- **Status:** ⬜ untried · 🔬 in current round · ✅ tested · 🏆 promoted to `main` · ❌ rejected (≤ baseline)
- **Verdict:** `win` (beats baseline, clear) · `edge` (slightly over baseline) · `tie` · `loss` ·
  `broken` (failed sanity) · `inconclusive` (need more A/B)
- **ELO** is from the blind, loudness-matched harness; baseline is anchored at ~1500. Report each
  candidate's best ELO and its Δ vs the baseline in that round.

## ⭐ The preference function (what actually wins — learned from rounds 1–2)

The listener's verdict, in their words: **"the bad ones sounded tinny or altered; the best ones
sounded like real voices."** The winning axis is **naturalness of the voice timbre**, NOT spatial
trickery. Every result fits this: `dfeq` (diffuse-field de-coloration) won both rounds because it makes
the voice *more natural*; the losers (`er_pattern`, `decorr_strong`, `rev_predelay`) all *altered* the
voice (slap-back, phasey-wide, echoey → "processed/tinny"). **Rule for all future candidates: a change
may only win if the voice still sounds like a real, natural voice.** Spatial/externalization levers are
worth adding ONLY when they don't color, smear, or "process" the voice. This supersedes the round-1
"be bold" rule for anything that touches voice timbre — bold is fine for *space*, not for *altering the
voice*.

## Hypothesis ledger (master checklist — at a glance)

| id | status | rounds | best ELO (Δ base) | verdict | one-line finding |
|----|--------|--------|-------------------|---------|------------------|
| `baseline`    | — | all | 1484 (anchor) | — | sanity floor (unmodified renderer) |
| `dfeq`        | 🏆→main-cand | 1,2 | **1544 / 1531** | **WIN ×2** | the durable win — "sounds like a real voice"; merged to research as round-3 base |
| `crossfeed`   | ✅ | 1 | 1500 | tie | imperceptible as tuned (−42 dB Δ); bold retest → crossfeed_strong |
| `front_notch` | ✅ retired | 1 | 1485 | tie | imperceptible (−55 dB Δ, fires 15% frames); too narrow/gated |
| `lf_body`     | ✅ retired | 1 | 1486 | tie | imperceptible (−51 dB Δ); +3 dB bell too gentle |
| `decorr`      | ✅ | 1 | 1500 | tie | perceptually nil on frontal content; bold retest → decorr_strong |
| `hrir_smooth` | ✅ retired | 1 | 1500 | tie | imperceptible (−40 dB Δ); ½-oct smoothing too gentle |
| `dfeq2`         | ✅ | 2 | 1532 | tie(dfeq) | deepened dfeq (±12 dB+shelf) split 1-1 w/ dfeq → ±8 dB is enough, don't push |
| `crossfeed_strong` | ✅ | 2 | 1514 | **edge** | bold −4 dB crossfeed beats baseline; positive secondary (doesn't alter timbre) |
| `rev_tilt`      | ✅ | 2 | 1500 | tie/subj+ | ELO-neutral but listener LIKED the warm deep room; refine subtle for r3 |
| `rev_predelay`  | ✅ | 2 | 1483 | loss | below baseline; bloom read as "altered" not better |
| `decorr_strong` | ✅ retired | 2 | 1484 | loss | below baseline; "altered/phasey" — alters the voice |
| `er_pattern`    | ✅ retired | 2 | 1455 | loss | worst; reflections above direct = slap-backy/"tinny", alters voice |
| `dfeq_xfeed`    | 🔬 | 3 | — | — | dfeq + bold crossfeed (the two positive levers stacked) |
| `dfeq_revtilt`  | 🔬 | 3 | — | — | dfeq + SUBTLE warm deep reverb (the room the listener liked) |
| `dfeq_predelay` | 🔬 | 3 | — | — | dfeq + subtle reverb bloom-after-voice |
| `dfeq_full`     | 🔬 | 3 | — | — | dfeq + crossfeed + subtle warm reverb (everything-that-helps blend) |
| `fd_itd`      | ⬜ | — | — | — | frequency-dependent ITD (full LF, less HF) |
| `near_pres`   | ⬜ | — | — | — | proximity/presence shaping for frontal sources |
| `src_spread`  | ⬜ | — | — | — | decorrelated near-copies — give the voice size |
| `air_damp`    | ⬜ | — | — | — | air-absorption + ER HF-damping naturalness |

> `fit_1p5` (frequency-scale 1.5) was used only to validate the harness — it's *personalization*,
> already shipped as the "Fit" slider on `main`, and is out of scope for this no-personalization
> experiment. Not a real candidate.

## Rounds

### Round 0 — harness validation (not a finding)
- **Pool:** `baseline`, `fit_1p5`. **Outcome:** confirmed blind A/B, instant switching, loudness
  match (−23 LUFS), and ELO-guided pairing all work. No conclusions drawn.

### Round 1 — 2026-06-30 — timbre + externalization (focused six)
- **Pool:** baseline, dfeq, crossfeed, front_notch, lf_body, decorr, hrir_smooth (7 total)
- **What each candidate does (peaks are raw render, pre-normalization):**
  - `dfeq` (peak 0.55) — diffuse-field EQ at HRTF-load: divides every HRIR by the ½-octave-smoothed,
    ±8 dB-clamped inverse of the RMS-over-directions common transfer function (L/R-symmetric, speech-band
    normalized). Strips the average "colored speaker" timbre, leaving direction-dependent cues. `hrtf.rs`.
  - `crossfeed` (peak 0.76) — Bauer/Meier headphone crossfeed on the final stereo bus: ~0.26 ms delayed,
    1.6 kHz-lowpassed, −9 dB copy of each channel into the other. Relaxes hard L/R isolation → less in-head.
    new `crossfeed.rs` + `lib.rs`.
  - `front_notch` (peak 0.76) — frontalness-gated pinna notch (~7.8 kHz, Q 2.2, −8 dB) cascaded onto the
    direct-path HRIR, strongest dead-ahead/ear-level, fading to identity toward sides/rear/elevation.
    Restores the "in front and below" monaural cue. `lib.rs`.
  - `lf_body` (peak 0.76) — low-mid body bell (220 Hz, Q 0.7, +3 dB) on the dry mono voice (pre-ITD).
    Adds chest/proximity warmth so a voice reads as a voice, not a thin speaker. `voice.rs` + `lib.rs`.
  - `decorr` (peak 0.81) — per-ear high-band (>1.5 kHz) interaural decorrelator: unit-magnitude all-pass
    with opposite-sign coeff per ear, LF (ITD) untouched. Widens image / pulls out of head. `voice.rs` + `lib.rs`.
  - `hrir_smooth` (peak 0.78) — ½-octave constant-Q magnitude smoothing + min-phase rebuild of every HRIR,
    plus modified-Shepard (Franke–Little) K=3 interp weighting (farthest neighbor → 0). Softens metallic
    notches + removes ear-to-ear stepping. `hrtf.rs`.
- **Comparisons:** 10 (ELO-guided). Most returned "too close" (r=0.5).
- **Standings (final ELO):**
  | rank | id | elo | games |
  |------|----|----|-------|
  | 1 | dfeq | 1544 | 3 |
  | 2 | crossfeed | 1500 | 3 |
  | 2 | decorr | 1500 | 3 |
  | 2 | hrir_smooth | 1500 | 3 |
  | 5 | lf_body | 1486 | 3 |
  | 6 | front_notch | 1485 | 3 |
  | 7 | baseline | 1484 | 2 |
- **Listener notes (by ear):** Listener reported **most pairs were indistinguishable**. `dfeq` was the
  only candidate that produced a perceptible, repeatable difference — it won every decisive game it
  played (beat baseline, front_notch, lf_body). Everything else tied baseline and each other.
- **Signal-delta check (post-normalization RMS vs baseline):** dfeq −32 dB, decorr −35 dB, hrir_smooth
  −40 dB, crossfeed −42 dB, lf_body −51 dB, front_notch −55 dB (fires only 15% of frames). The two
  smallest deltas (front_notch, lf_body) were physically too small to hear. decorr had a large *sample*
  delta but a perceptually null effect on mostly-frontal content.
- **Outcome:** **`dfeq` wins round 1** — the single audible improvement. All other round-1 levers were
  tuned too gently (every candidate prompt said "subtle/gentle") and landed below the perceptual floor.
- **Root-cause lesson (process):** A blind A/B cannot reward a change the listener can't hear. Candidates
  MUST be tuned to be **unmistakably audible**; a subtle-but-correct change is a failed candidate. Baked
  two fixes: (1) CANDIDATE_PROMPT now demands a boldly-audible change + self-check; (2) ingest.py flags
  any candidate within −45 dB RMS of baseline as "likely imperceptible".
- **Deepen / revise:** dfeq is the keeper → push it harder (`dfeq2`). Pivot the rest to intrinsically loud
  levers, especially **room/reverb** (the project's #1 externalization lever, untouched in round 1):
  `rev_tilt`, `er_pattern`, `rev_predelay`. Retest width only if cranked loud (`crossfeed_strong`,
  `decorr_strong`). Retired as tuned: `front_notch`, `lf_body`, `hrir_smooth` (revisit only if bolder).
- **Promoted?** none yet — `dfeq` is the leading promotion candidate but stays in the pool to be
  challenged by round 2 before any merge-to-main + parity check.

### Round 2 — 2026-06-30 — room/reverb levers + bolder retests (the "make it audible" round)
- **Pool:** baseline, **dfeq** (round-1 champion, carried as the bar), dfeq2, rev_tilt, er_pattern,
  rev_predelay, crossfeed_strong, decorr_strong (8 total)
- **Theme:** every candidate tuned to be unmistakably audible (round-1 lesson). All 8 clear the
  perceptibility gate — closest is rev_predelay at −28 dB vs baseline, vs the −45 dB flag.
- **What each candidate does (peak = raw render; Δ = loudness-matched mono RMS vs baseline):**
  - `dfeq2` (peak 0.58, Δ −1.4 dB) — deepened dfeq: clamp ±8→±12 dB, smoothing ½→⅓-oct, +3 dB
    presence shelf >3.5 kHz. Does the winning de-coloration harder. `hrtf.rs`.
  - `rev_tilt` (peak 0.76, Δ −26 dB) — FDN wet ×2.8 (~+9 dB D/R toward the room) + dark output LP
    (~2.4 kHz) + extra in-loop HF damping. Pushes voices into the room, tail warm not harsh. `reverb.rs`.
  - `er_pattern` (peak 0.92, Δ −4.6 dB) — early-reflection gain ×2.4 (reflections now ABOVE direct)
    + REFLECT_PER_SOURCE 8→16 (denser image cloud). Strong "in a room" early-cue. `lib.rs`.
  - `rev_predelay` (peak 0.76, Δ −28 dB) — late-reverb onset pushed to t_mix+30 ms ≈ 50 ms, send level
    kept hot, so the room blooms a clear beat after the voice (direct/room separation). `reverb.rs`.
  - `crossfeed_strong` (peak 0.55, Δ −11 dB) — bold Bauer crossfeed: −4 dB cross, 0.3 ms, ~900 Hz LP.
    L/R correlation −0.079→−0.008 (pulls together, not mono-collapsed). `lib.rs`.
  - `decorr_strong` (peak 0.48, Δ −0.0 dB) — 3-stage Schroeder all-pass decorrelator per ear above a
    ~700 Hz crossover (LF/ITD preserved exactly), opposite sign per ear. Wide/enveloping. `voice.rs`+`lib.rs`.
- **Comparisons:** 16 (ELO-guided).
- **Standings (final ELO):**
  | rank | id | elo | games |
  |------|----|----|-------|
  | 1 | dfeq2 | 1532 | 4 |
  | 2 | dfeq | 1531 | 4 |
  | 3 | crossfeed_strong | 1514 | 3 |
  | 4 | baseline | 1500 | 4 |
  | 4 | rev_tilt | 1500 | 5 |
  | 6 | decorr_strong | 1484 | 4 |
  | 7 | rev_predelay | 1483 | 4 |
  | 8 | er_pattern | 1455 | 4 |
- **Listener notes (by ear):** Overall "mixed / quite similar" (ELO spread only ~77 pts). Key qualitative
  verdict: **"the bad ones sounded tinny or altered; the best ones sounded like real voices."** Listener
  also **liked the subtle deep reverb** of one room candidate (rev_tilt or rev_predelay — unsure which).
- **Outcome:** **dfeq de-coloration wins again** (dfeq ≈ dfeq2 at the top). `dfeq2`'s deepening (±12 dB +
  presence shelf) split 1-1 with `dfeq` → no gain; **±8 dB dfeq is the keeper, don't push harder.**
  `crossfeed_strong` is a real positive secondary (1514, > baseline) — bold crossfeed cleared the bar the
  gentle round-1 version couldn't, and it doesn't alter timbre. The room levers underperformed in blind
  A/B: `er_pattern` worst (reflections above direct = slap-backy/"altered"), `rev_predelay` below baseline.
  This matches the preference function: anything that *alters the voice* loses.
- **Deepen / revise:** Promote `dfeq` (done — merged onto research branch as round-3 base; → main after
  parity). Round 3 = **combinations on top of dfeq**, each held to "voice must still sound real":
  `dfeq_xfeed` (dfeq+crossfeed), `dfeq_revtilt` (dfeq + *subtle* warm reverb), `dfeq_predelay`,
  `dfeq_full`. Reverb must be dialed SUBTLE (the bold round-2 versions altered too much). Retired as
  losers: `er_pattern`, `decorr_strong`, `rev_predelay`(bold), `dfeq2`, plus round-1 retirees.
- **Promoted?** `dfeq` → merged onto `research/shootout` (commit on branch) as the round-3 foundation;
  final promotion to `main` pending a parity re-check after round 3 settles the combo.

### Round 3 — 2026-06-30 — combinations on the dfeq foundation ("does any spatial lever add to dfeq?")
- **Pool:** baseline, dfeq (the bar), dfeq_xfeed, dfeq_revtilt, dfeq_predelay, dfeq_full (6 total). dfeq is
  now merged onto the research branch, so all four combos = dfeq + their spatial lever, built identically.
- **Bar to clear:** the voice must still sound like a real, natural voice (the preference function). The
  spatial lever only wins if it adds space/externalization WITHOUT making the voice tinny/altered.
- **What each adds on top of dfeq (peak = raw; Δ = loudness-matched mono RMS vs baseline):**
  - `dfeq_xfeed` (peak 0.36, Δ −2.3 dB) — + Bauer crossfeed on final bus (0.3 ms, ~900 Hz LP, −4 dB,
    mono-unity normalized). Externalization without coloring the voice. `lib.rs`.
  - `dfeq_revtilt` (peak 0.55, Δ −3.3 dB) — + subtle warm reverb: FDN wet ×1.5 + dark tail LP 2.8 kHz
    (unity at DC, wet-only so decay/RT60 unchanged). The "subtle deep" room the listener liked. `reverb.rs`.
  - `dfeq_predelay` (peak 0.55, Δ −3.3 dB) — + gentle bloom: FDN tail pre-delay t_mix+15 ms with a
    SOFTER send (≈0.64 vs 0.78, not hot) + warm tilt. Room opens a beat after the voice. `reverb.rs`.
  - `dfeq_full` (peak 0.37, Δ −2.4 dB) — + crossfeed (−4.5 dB) AND subtle reverb (wet ×1.45, LP 2.75 kHz)
    stacked conservatively. The "everything that helps" blend. `lib.rs` + `reverb.rs`.
- **Note:** dfeq_revtilt/dfeq_predelay show the same −3.3 dB Δ as dfeq alone — the reverb refinements are
  subtle relative to dfeq's recolor (by design). The A/B will show if they're distinguishable from dfeq.
- **Comparisons:** _pending listen_
- **Standings (final ELO):** _pending listen_
- **Listener notes (by ear, per candidate):** _pending listen_
- **Outcome:** _pending listen_
- **Deepen / revise:** _pending listen_
- **Promoted?** _pending_

<!-- Copy the template below for each real round. Fill it in AFTER the human listens. -->
<!--
### Round N — YYYY-MM-DD — <theme, e.g. "timbre + externalization">
- **Pool:** baseline, <ids…>
- **Comparisons:** <count> (ELO-guided)
- **Standings (final ELO):**
  | rank | id | elo | games |
  |------|----|----|-------|
  | 1 | … | … | … |
- **Listener notes (by ear, per candidate):**
  - `<id>`: <front? timbre? width? side localization? distance? any artifacts?>
- **Outcome:** <winner, or "nothing beat baseline", or "X and Y both promising">
- **Deepen / revise:** <new or refined hypotheses this round suggests — add them to Backlog too>
- **Promoted?** <id → main commit, or none>
-->

## Backlog (ideas to try / deepen — prioritized; grows from findings)

- **RULE (from round 1): only test changes likely to be CLEARLY audible.** Subtle = wasted round.
- (round 2, in flight) `dfeq2`, `rev_tilt`, `er_pattern`, `rev_predelay`, `crossfeed_strong`, `decorr_strong`
- remaining deck, only if made bold: `fd_itd`, `near_pres`, `src_spread`, `air_damp`
- combine winners (e.g. dfeq × best-room lever) once round 2 ranks the room levers
- retired-as-tuned (round 1, imperceptible): `front_notch`, `lf_body`, `hrir_smooth` — revisit only bolder

## Promoted to `main`

- _none yet_ — when a candidate wins and survives a parity re-check, record `id`, the commit, and
  why here.
