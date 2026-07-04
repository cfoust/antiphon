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
| `motiongain`  | ⚠️ | 4 | **1530** | win* | TOP of round 4 — even with broken (350 ms) tracking. *Re-test after lag fix. |
| `dfeq_erb`    | ✅ | 4 | 1516 | tie(dfeq) | regularized DFE == dfeq (cleaner, not better) → freeze the DFE per survey |
| `revsend`     | ✅ | 4 | 1457 | loss | below baseline; decorrelated send reverb STILL lost — reverb keeps failing |
| `hrtf_ari`    | ✅ | 4 | 1501 | tie | ARI generic set ≈ KEMAR here; inconclusive (maybe try KU100/avg) |
| `motion_2p5`  | ❌ | 5 | ~1468 | loss | 2.5× rotation overshoots (≤ baseline); 1.7× (motiongain) is the sweet spot — don't push |
| `parallax`    | ✅ | 5 | ~1500 | tie | dir-only 2.5× neutral; full-position `parallax_pos` is the better formulation |
| `interp_xfade`| ✅ | 5 | ~1484 | tie | continuous K=4 interp didn't clearly help in the (confounded) round |
| `timbrelock`  | 🔬 | 6 | — | — | **HEADLINE.** per-dir common-mode flattening (Merimaa 2009), stack on dfeq str 0.65; the proven TIMBRE axis; offline-rankable (−1.4 dB); parity −150 dBFS. **NOT yet genuinely judged** → clean offline A/B |
| `frontgain`   | 🔬 | 6 | — | — | frontal-adaptive motion gain (1.3× within ±30° → 1.0 by ±60°); not yet judged |
| `parallax_pos`| 🔬 | 6 | — | — | full-position parallax 1.8× near-gated; topped the confounded r5 export (1546) but UNCONFIRMED; folded into `champion` |
| `champion`    | 🔬 | 6 | — | — | dfeq + parallax_pos(1.8×) + motiongain(1.7×) — bank the spatial wins in one engine |
| `onsetkick`   | 🔬 | 6 | — | — | motion-onset/accel emphasis (Wallach 1940): leaky world-lock, ≤1.18× kick, τ=150 ms, IDENTITY at rest. Built; wobble risk → A/B vs flat 1.0× and motiongain |
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
- **Comparisons:** 12 (ELO-guided).
- **Standings (final ELO):** dfeq 1531 · dfeq_full 1529 · dfeq_revtilt 1500 · dfeq_xfeed 1499 ·
  dfeq_predelay 1485 · baseline 1456.
- **Outcome:** **dfeq alone is the whole win.** `dfeq_full` (dfeq+crossfeed+subtle reverb) tied dfeq
  exactly — the spatial levers add nothing distinguishable on top of de-coloration; the rest are
  neutral; baseline is now clearly last (dfeq's superiority is solid). No combination beat dfeq.
- **⚠ Methodological ceiling discovered:** the shootout scene uses a FIXED head. That deliberately
  exposes front-collapse, but it means the test is **structurally blind to the single most powerful
  externalization cue — dynamic head-motion parallax.** A static A/B can essentially only reward
  *timbre*, which is exactly why a timbre fix (dfeq) dominates and every spatial lever ties. To
  evaluate externalization innovations we need an INTERACTIVE head-motion test in the app, not the
  offline WAV A/B. This reframes rounds 2–3: spatial levers didn't fail, they were *untestable here*.
- **Deepen / revise:** (1) Promote `dfeq` to `main` (parity re-check) — it's the confirmed win.
  (2) Next ideas must be audacious AND tested on the right rig — see the "Audacious frontier" backlog.
- **Promoted?** dfeq → ready for `main` promotion (parity check pending).

### Round 4 — 2026-06-30 — FIRST LIVE (head-tracked) round; literature-grounded
- **Rig:** the realtime head-tracked rig (`tools/shootout/live/`), NOT the offline WAV A/B. One voice
  fixed ~30° off-forward; you turn your head. This round can finally reward dynamic externalization.
- **Informed by** `scratch/research.md` (decision-ready survey). It validated timbre/de-coloration as
  the primary axis, named the failure mode (touching the direct sound), and reshaped the candidates:
- **Pool (engines):** baseline, dfeq (champion), + 4 new:
  - `dfeq_erb` — A1 (survey #1): power-avg DFE, Tylka log-symmetric **⅓-oct** smoothing, **Tikhonov
    β=0.2·peak** inverse (no notch-ringing), asymmetric **+8/−12 dB** clamp. dfeq done right. `hrtf.rs`.
  - `revsend` — B1: **interaurally decorrelated** late reverb (L/R read the 16 FDN lines at different
    delays → low IACC) on the SEND only, **T60 0.45 s, pre-delay ~10 ms, high DRR**, dry voice byte-
    identical. The survey: only *decorrelated* reverb externalizes; diotic does nothing. `reverb.rs`.
  - `motiongain` — B2 (audacious): amplify head-orientation **1.7×** about its own axis (`Quat::
    scale_angle`), so a small real head turn renders as a larger world-locked sweep. Timbre untouched.
    Offline WAV ≈ baseline by design (fixed head) — effect is head-motion-only. `math.rs`+`lib.rs`.
  - `hrtf_ari` — C1: same dfeq engine but the **ARI** generic HRTF set instead of KEMAR (Romigh &
    Simpson 2014: raw KEMAR is a weak default). Wired via a per-engine asset sidecar; no code change.
- **Standings (final ELO):** motiongain 1530 · dfeq_erb 1516 · dfeq 1513 · hrtf_ari 1501 ·
  baseline 1484 · revsend 1457.
- **Outcome:** **`motiongain` won the round** — amplifying head rotation 1.7× topped everything, even
  though the tracking was badly lagged (see below). `dfeq_erb` tied `dfeq` (split 0.5/0.5 twice) → the
  regularized DFE is a cleaner equal, not a win; per the survey, freeze the DFE. `revsend` LOST (below
  baseline) — even the "correct" decorrelated send reverb failed; reverb has now lost in every round.
  `hrtf_ari` was neutral (ARI ≈ KEMAR for this listener).
- **⚠ Confound: head-tracking lag ~300–500 ms.** The harness smoothed pose with a fixed one-pole
  (α=0.35) that settled in ~350 ms — far above the <60 ms the dynamic cue needs (>73 ms *hurts*
  localization, per Brungart). So motiongain's win came THROUGH a broken pipeline — likely
  understated. **Fixed:** replaced with a One Euro filter (low lag in motion) + 45 ms velocity
  prediction + 60 fps camera + interactive audio latency + a live fps readout. **Re-test motiongain
  (and the whole dynamic-cue thesis) on the fixed rig before concluding.**
- **Dropped this round (per survey):** headphone-comp (A4 — only worth it after a better DFE) and DDSP
  (cheaper concrete wins exist first). `er_pattern`/discrete reflections stay retired (slap-back).
- **Deepen / revise:** (1) re-run motiongain vs baseline/dfeq on the fixed (low-lag) rig; sweep the
  gain (1.3 / 1.7 / 2.2). (2) Reverb is 0-for-4 — likely the wrong lever for this listener/scene; shelve
  unless room-matching (mic RT60) changes it. (3) dfeq_erb can replace dfeq on main (cleaner) but no
  rush. (4) hrtf_ari inconclusive → only worth a KU100/population-average bake if motion plateaus.

### Round 5 — 2026-06-30 — all-in on dynamic/spatial cues (the live rig's home turf)
- **Rationale:** timbre is solved (`dfeq` on main); reverb is 0-for-4 (dead); the frontier is dynamic
  cues, which only the live head-tracked rig can judge. Research backs this as the #1 non-coloring lever.
- **⚠ Rig fix mid-stream:** discovered the live harness was sending **orientation only** — head
  POSITION was pinned to (0,0,0), so NO translation parallax (a major externalization cue) the whole
  time, despite the renderer supporting 6DoF. Now sends filtered head translation (toggle "6DoF
  (lean→parallax)", default on). This alone should boost externalization for every engine.
- **Pool (engines):** baseline, dfeq (timbre anchor), motiongain (rotation 1.7×, carried), + 3 new:
  - `motion_2p5` — rotation amplification **2.5×** (sweep up from 1.7×). `math.rs`+`lib.rs`.
  - `parallax` — amplify head-translation **2.5×** (lean → exaggerated source parallax); distance
    attenuation kept on TRUE position (no loudness pumping), only the HRTF/ITD direction amplified. `lib.rs`.
  - `interp_xfade` — A2: modified-Shepard/Franke–Little continuous K=4 interpolation of HRIR **and** ITD
    (farthest neighbor tapers to 0 → C0-continuous as the head turns) to kill the "ear-to-ear" comb-step
    on motion, without magnitude smoothing (preserves timbre). `hrtf.rs`.
- **Added mid-round (novel-techniques pass, `scratch/novel-techniques.md`):** 3 literature-grounded
  candidates folded into the same pool —
  - `timbrelock` — per-direction common-mode flattening (Merimaa 2009 AES 7912): hold the voice's
    tone color constant across directions while preserving ILD+ITD. The principled generalization of
    `dfeq` (global) → per-direction. STACKED on dfeq, strength 0.65. **Offline-rankable** (−1.4 dB,
    the largest perceptibility delta of any candidate) AND live; **passed parity (−150 dBFS)** so
    promotion-ready if it wins. `hrtf.rs` (`timbre_constancy_eq`).
  - `frontgain` — azimuth-adaptive head-rotation gain: PEAK 1.3× within ±30° of the median plane
    (the front dead zone where head-motion helps most; McAnally & Martin 2014), →1.0 by ±60°. Spends
    `motiongain`/`motion_2p5`'s budget where it pays. `math.rs`(`scale_angle`)+`lib.rs`. Live-only.
  - `parallax_pos` — a `parallax` SWEEP variant: amplifies the head POSITION 1.8× gated to near
    sources (<1.5 m) so distance/DVF/ILD/level stay self-consistent with the exaggerated lean
    (vs `parallax`, which amplifies the HRTF/ITD direction only). A/B the two to learn which parallax
    formulation externalizes without "darting". `math.rs`(`Vec3::scale`)+`lib.rs`. Live-only.
- **Status:** 9 live engines total now built + loudness-trimmed (`out/shootout/wasm/manifest.json`):
  baseline, dfeq, motiongain, motion_2p5, parallax, parallax_pos, interp_xfade, frontgain, timbrelock.
  Offline pool also has `timbrelock` (others are motion-null offline). **Awaiting the live listen**
  (ideally on WIRED headphones — see scratch/latency.md). Candidate diffs on `worktree-agent-*`:
  timbrelock=abcae1a7, frontgain=a43cd5f6, parallax_pos=a7c666e3, parallax(orig)=a401d473.
- **Test plan:** reset the harness (prior votes confounded by lag/Bluetooth + the orientation-only bug);
  with 6DoF on and head moving, A/B the motion sweep (dfeq vs motiongain vs motion_2p5), parallax, and
  interp_xfade. Also worth toggling 6DoF off/on to feel the parallax contribution directly.

### Round 5 — CORRECTION (post-hoc)
The novel-techniques candidates (`timbrelock`, `frontgain`, `parallax_pos`) were folded into the
manifest but were **NOT genuinely judged** — they belong to round 6. The confounded export's numbers
for them are not real listens (esp. `timbrelock` ≈ 1484 = near-default, the listener confirmed it was
never actually in the pool they evaluated). Treat round 5's trustworthy signal as: **`motiongain`
(1.7×) > `motion_2p5` (2.5×)** — more rotation overshoots — and `dfeq` still strong on timbre.
`parallax_pos`'s apparent r5 win is a preview, to be confirmed cleanly.

### Round 6 — 2026-06-30 — staged (headline: timbrelock on the timbre axis)
- **Part A — timbre 3-way, ON THE LIVE RIG (the headline, decisive):** pool = `baseline`, `dfeq`,
  `timbrelock` in the LIVE manifest (`/tools/shootout/live/` — same rig as everything else; do NOT use
  the deprecated offline `/elo/` page). It's a focused 3-engine pool so the timbre candidate isn't buried
  in a spatial pool again. Judge timbre by ear: hold still OR sweep your head across the fixed source and
  listen for which sounds most like a real, consistent voice. Question: does `timbrelock` beat `dfeq`?
  If yes → promote (parity already −150 dBFS). Perceptibility: dfeq −3.3 dB, timbrelock −1.4 dB vs
  baseline. Non-timbre engines parked in `out/shootout/hold/wasm/`.
- **Part B — LIVE dynamic/spatial round (follow-on):** the full motion family + parallax + the bank, on
  `/tools/shootout/live/` with 6DoF ON. Pool (7): `baseline`, `dfeq`, plus
  - rotation strategies: `motiongain` (flat 1.7×), `frontgain` (frontal-adaptive 1.3×→1.0), `onsetkick`
    (transient onset kick ≤1.18×, IDENTITY at rest) — A/B which motion model externalizes without swimming;
  - `parallax_pos` (full-position translation parallax 1.8× near-gated);
  - `champion` (dfeq + parallax_pos + motiongain) — the bank.
  All 7 engines built + parity-safe (geometry-only, except dfeq). If `timbrelock` wins Part A, rebuild
  `champion` on the `timbrelock` timbre base.
- **Status:** Part A staged + ingested now (offline 3-way). Part B's 7 engines all built; the live manifest
  will be re-staged after the timbre verdict (kept sequential so each pool stays clean). Non-timbre WAVs
  parked in `out/shootout/hold/`.

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

## ⛔ CEILING VERDICT (2026-06-30) — adversarial red-team, see `scratch/ceiling-verdict.md`

5 parallel adversarial subagents red-teamed the next slate. **We are at the generic-HRTF ceiling for
this listener.** ~50% of the residual realism gap is generic-HRTF spectral mismatch (front-collapse)
= a **personalization** problem = out of current scope. dfeq captured the in-scope timbre win; ~25
candidates since produced one edge + one motion result, all else tied/lost — that's the signature of
a ceiling, not bad luck. **Stop generating in-scope single-DSP-block candidates; they're noise here.**
- **KILLED (don't build):** `hp_eq` (can't target this listener's headphone → coin-flip, confounded
  w/ dfeq) · `hrtf_ku100`/population-avg (same class as the `hrtf_ari` tie; pop-avg = worse dfeq) ·
  `brir_conv` + `room_match` (revsend's byte-identical-dry-path loss proves reverb's failure is the
  *unexpected room*, not tuning — divergence unavoidable w/o a measured room) · `fd_itd`, `near_pres`,
  `src_spread`, `air_damp` (sub-floor, or only audible by coloring the voice).
- **Predicted dead among the unjudged:** `frontgain` (1.3× inside the rotation JND + swimming),
  `onsetkick` (sub-JND or wobble), `champion` (round-3 dfeq_full already showed stacking washes out).
- **Worth the listener's time:** `timbrelock` vs dfeq (decisive on the timbre axis — if it ties like
  dfeq2/dfeq_erb, FREEZE timbre) and `parallax_pos` (the one preference-safe spatial lever).
- **THE decisive experiment:** render the listener's OWN Fit-personalized HRTF as an upper-bound
  **oracle** vs dfeq on the live rig. If it externalizes the front → ceiling = personalization →
  scope change. If even it fails → redirect to designed-BRIR room + gentle HpEQ. One afternoon.
- **One last reverb shot, then bury:** `revsend` ALONE vs baseline/dfeq on the fixed low-lag 6DoF
  rig, head moving, judging *externalization not timbre*. Lose → reverb is done here forever.

## Backlog (ideas to try / deepen — prioritized; grows from findings)

- **RULE (from round 1): only test changes likely to be CLEARLY audible.** Subtle = wasted round.
- **RULE (ceiling verdict): in-scope single-block DSP tweaks are exhausted — see above. Next real
  lever is a SCOPE CHANGE (lightweight personalization), gated on the oracle experiment.**
- remaining deck — **all KILLED by red-team** (kept for the record): `fd_itd`, `near_pres`, `src_spread`, `air_damp`
- retired-as-tuned (round 1, imperceptible): `front_notch`, `lf_body`, `hrir_smooth` — revisit only bolder

## Promoted to `main`

- **`dfeq` (diffuse-field EQ)** → `main` commit `95148e2` (2026-06-30). Won rounds 1–3; the durable
  "sounds like a real voice" win. Parity re-checked: native↔wasm error **−153.2 dBFS** (< −90). The
  one change (`crates/antiphon-dsp/src/hrtf.rs`, `diffuse_field_eq` in `HrtfDb::from_asset`) is on main.

## Live (realtime, head-tracked) A/B rig — `tools/shootout/live/`

Built 2026-06-30 to fix the fixed-head ceiling (round 3). Each candidate now also builds a **wasm
engine** (`bash tools/shootout/build-live.sh <id>` → `out/shootout/wasm/<id>.wasm`); the page holds
two engines in one AudioWorklet, runs BOTH on the same live head pose + a world-fixed voice, and
equal-power crossfades between them (per-engine loudness trim from the offline ingest). Both run
continuously so tails stay warm and the A/B is instant + click-free. Scene: one voice fixed ~30°
off-forward; you turn your head to audition orientations — so it finally exercises the dynamic
externalization cue. Same blind ELO logic as the offline harness. Bootstrapped + smoke-tested with
`baseline` vs `dfeq` (engines differ 3.4 dB, finite). Serve from repo root → `/tools/shootout/live/`.
Candidate contract: keep the antiphon-ffi C ABI identical across engines (edit `antiphon-dsp` internals).
