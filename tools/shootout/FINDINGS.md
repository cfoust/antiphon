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

## Hypothesis ledger (master checklist — at a glance)

| id | status | rounds | best ELO (Δ base) | verdict | one-line finding |
|----|--------|--------|-------------------|---------|------------------|
| `baseline`    | — | all | ~1500 (anchor) | — | sanity floor (unmodified renderer) |
| `dfeq`        | ⬜ | — | — | — | diffuse-field EQ — kill "speaker" coloration |
| `crossfeed`   | ⬜ | — | — | — | mild low-passed crossfeed (externalization) |
| `front_notch` | ⬜ | — | — | — | sharpen frontal pinna notch (front-back) |
| `lf_body`     | ⬜ | — | — | — | LF body/chest shelf — voice not speaker |
| `decorr`      | ⬜ | — | — | — | subtle L/R decorrelation (width / less in-head) |
| `hrir_smooth` | ⬜ | — | — | — | window/interp tweak — cut comb-filter timbre |
| `fd_itd`      | ⬜ | — | — | — | frequency-dependent ITD (full LF, less HF) |
| `er_pattern`  | ⬜ | — | — | — | denser/earlier first-order reflections |
| `near_pres`   | ⬜ | — | — | — | proximity/presence shaping for frontal sources |
| `rev_tilt`    | ⬜ | — | — | — | reverb tilt + direct-to-reverberant ratio |
| `src_spread`  | ⬜ | — | — | — | decorrelated near-copies — give the voice size |
| `air_damp`    | ⬜ | — | — | — | air-absorption + ER HF-damping naturalness |

> `fit_1p5` (frequency-scale 1.5) was used only to validate the harness — it's *personalization*,
> already shipped as the "Fit" slider on `main`, and is out of scope for this no-personalization
> experiment. Not a real candidate.

## Rounds

### Round 0 — harness validation (not a finding)
- **Pool:** `baseline`, `fit_1p5`. **Outcome:** confirmed blind A/B, instant switching, loudness
  match (−23 LUFS), and ELO-guided pairing all work. No conclusions drawn.

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

- (round 1 default focus) `dfeq`, `crossfeed`, `front_notch`, `lf_body`, `decorr`, `hrir_smooth`
- then the remainder of the deck: `fd_itd`, `er_pattern`, `near_pres`, `rev_tilt`, `src_spread`,
  `air_damp`
- combine winners (e.g. best-timbre × best-front) once individual levers are ranked

## Promoted to `main`

- _none yet_ — when a candidate wins and survives a parity re-check, record `id`, the commit, and
  why here.
