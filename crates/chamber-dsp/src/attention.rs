//! The "an agent is waiting" attention cue.
//!
//! A soft minor-7th arpeggio that BLOOMS at one ear (random per pulse, so you can't tune it out),
//! quietly, and BUILDS the longer agents wait unheard: over `build_minutes` the gain ramps
//! 0 → `gain_max` and the pulse rate climbs from one-per-`period_start`s to one-per-`period_end`s.
//! The number of notes per pulse == the number of waiting agents.
//!
//! Synthesized here in the shared core with a seeded, deterministic RNG so the native and wasm
//! hosts produce identical audio (the "random" ear is the same sequence on both). The [`Renderer`]
//! feeds this through the same near-field DVF + position-based reverb path as any voice, so it
//! shares the acoustic space with the agent voices.
//!
//! [`Renderer`]: crate::Renderer

use core::f32::consts::PI;

const MAX_NOTES: usize = 24; // voice pool (one pulse uses up to AGENT_CAP notes; the rest decay)
const AGENT_CAP: usize = 8; // most notes we stack in a single pulse
const MINOR7: [i32; 4] = [0, 3, 7, 10]; // minor-7th arpeggio scale degrees (semitones)

/// Timbre + build parameters. Defaults are the values tuned by ear in `web/arp-lab.html`.
#[derive(Clone, Copy)]
pub struct AttentionCfg {
    pub build_minutes: f32, // M: minutes to ramp from silent → full urgency
    pub root_hz: f32,
    pub attack: f32,
    pub decay: f32,
    pub brightness: u32, // number of harmonic partials (1 = pure)
    pub detune: f32,
    pub trem_rate: f32,
    pub trem_depth: f32,
    pub stride: f32,   // seconds between successive notes in a pulse
    pub humanize: f32, // ± timing jitter (seconds)
    pub warmth_hz: f32, // output low-pass cutoff
    pub distance: f32, // metres from head centre (near-field)
    pub send: f32,     // reverb send
    pub gain_max: f32, // gain at full urgency
    pub period_start: f32, // seconds/pulse at urgency 0
    pub period_end: f32,   // seconds/pulse at urgency 1
}

impl Default for AttentionCfg {
    fn default() -> Self {
        AttentionCfg {
            build_minutes: 10.0,
            root_hz: 220.0,
            attack: 1.015,
            decay: 1.3,
            brightness: 1,
            detune: 0.003,
            trem_rate: 5.0,
            trem_depth: 0.08,
            stride: 0.315,
            humanize: 0.03,
            warmth_hz: 6100.0,
            distance: 0.39,
            send: 0.54,
            gain_max: 0.35,
            period_start: 30.0,
            period_end: 10.0,
        }
    }
}

/// Deterministic LCG (same constants as the render harness) — keeps native/wasm identical.
struct Rng(u32);
impl Rng {
    #[inline]
    fn next_u32(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        self.0
    }
    #[inline]
    fn unit(&mut self) -> f32 {
        (self.next_u32() >> 8) as f32 / (1u32 << 24) as f32 // [0,1)
    }
    #[inline]
    fn bipolar(&mut self) -> f32 {
        self.unit() * 2.0 - 1.0
    }
}

#[derive(Clone, Copy)]
struct Note {
    active: bool,
    t: f32, // seconds since onset; starts negative to encode the intra-pulse start delay
    freq: f32,
    amp: f32,
}
impl Note {
    const OFF: Note = Note { active: false, t: 0.0, freq: 0.0, amp: 0.0 };
}

pub struct AttentionCue {
    sr: f32,
    cfg: AttentionCfg,
    rng: Rng,
    agents: u32,
    active: bool,
    elapsed: f32, // seconds since the cue became active (drives urgency)
    pulse_phase: f32, // accumulates at 1/period(urgency) per second; a pulse fires each time it ≥ 1
    notes: [Note; MAX_NOTES],
    lp_state: f32, // warmth low-pass state
    ear_sign: f32, // +1 right / -1 left, chosen per pulse
    cur_gain: f32, // urgency() * gain_max, updated per block
}

impl AttentionCue {
    pub fn new(sample_rate: f32, seed: u32, cfg: AttentionCfg) -> AttentionCue {
        AttentionCue {
            sr: sample_rate,
            cfg,
            rng: Rng(seed | 1),
            agents: 0,
            active: false,
            elapsed: 0.0,
            pulse_phase: 0.0,
            notes: [Note::OFF; MAX_NOTES],
            lp_state: 0.0,
            ear_sign: 1.0,
            cur_gain: 0.0,
        }
    }

    /// Number of waiting agents. 0 silences the cue and resets the build clock; the first agent
    /// (re)starts it from silence.
    pub fn set_agents(&mut self, n: u32) {
        let n = n.min(AGENT_CAP as u32);
        if n > 0 && self.agents == 0 {
            self.active = true;
            self.elapsed = 0.0;
            self.pulse_phase = 1.0; // first pulse right away (inaudible at urgency 0, then builds)
        } else if n == 0 {
            self.active = false;
            self.elapsed = 0.0; // active notes keep decaying; scheduling stops
        }
        self.agents = n;
    }

    pub fn set_build_minutes(&mut self, m: f32) {
        self.cfg.build_minutes = m.max(0.01);
    }

    /// True while the cue is building OR any note is still decaying — the Renderer only
    /// spatializes it when this holds, and ramps the voice to silence once it goes false.
    pub fn needs_render(&self) -> bool {
        self.active || self.notes.iter().any(|nt| nt.active)
    }

    #[inline]
    fn urgency(&self) -> f32 {
        (self.elapsed / (self.cfg.build_minutes * 60.0)).clamp(0.0, 1.0)
    }

    pub fn gain(&self) -> f32 {
        self.cur_gain
    }
    pub fn send(&self) -> f32 {
        self.cfg.send
    }
    pub fn distance(&self) -> f32 {
        self.cfg.distance
    }
    pub fn ear_sign(&self) -> f32 {
        self.ear_sign
    }

    fn trigger_pulse(&mut self) {
        // random ear for this pulse
        self.ear_sign = if self.rng.unit() < 0.5 { -1.0 } else { 1.0 };
        let count = self.agents.max(1).min(AGENT_CAP as u32) as usize;
        let norm = 0.9 / (count as f32).sqrt(); // keep the summed peak roughly bounded
        for k in 0..count {
            let semi = MINOR7[k % 4] + 12 * (k / 4) as i32;
            let freq = self.cfg.root_hz * 2f32.powf(semi as f32 / 12.0);
            let delay = k as f32 * self.cfg.stride + self.cfg.humanize * self.rng.bipolar();
            // find a free note slot (steal the oldest if the pool is somehow full)
            let slot = self
                .notes
                .iter()
                .position(|nt| !nt.active)
                .unwrap_or_else(|| {
                    let mut oldest = 0;
                    for i in 1..MAX_NOTES {
                        if self.notes[i].t > self.notes[oldest].t {
                            oldest = i;
                        }
                    }
                    oldest
                });
            self.notes[slot] = Note { active: true, t: -delay.max(0.0), freq, amp: norm };
        }
    }

    /// Advance the schedule and synthesize `frames` mono samples into `out` (overwriting).
    pub fn render(&mut self, out: &mut [f32], frames: usize) {
        let dt = 1.0 / self.sr;

        // --- schedule pulses: accumulate phase at 1/period, where period tracks urgency now
        // (30 s/pulse at urgency 0 → 10 s/pulse at urgency 1), so the rate responds as it builds ---
        if self.active {
            self.elapsed = (self.elapsed + frames as f32 * dt).min(self.cfg.build_minutes * 60.0);
            let u = self.urgency();
            let period = (self.cfg.period_start + (self.cfg.period_end - self.cfg.period_start) * u).max(0.5);
            self.pulse_phase += frames as f32 * dt / period;
            let mut guard = 0;
            while self.pulse_phase >= 1.0 && guard < 8 {
                self.pulse_phase -= 1.0;
                self.trigger_pulse();
                guard += 1;
            }
        }
        self.cur_gain = self.urgency() * self.cfg.gain_max;

        // --- synthesize active notes ---
        for v in out.iter_mut().take(frames) {
            *v = 0.0;
        }
        let (attack, decay) = (self.cfg.attack, self.cfg.decay);
        let (tr, td) = (self.cfg.trem_rate, self.cfg.trem_depth);
        let (bright, det) = (self.cfg.brightness.max(1), self.cfg.detune);
        let end_t = attack + decay * 6.0; // deactivate once the tail is ~-52 dB
        for note in self.notes.iter_mut() {
            if !note.active {
                continue;
            }
            let mut t = note.t;
            for v in out.iter_mut().take(frames) {
                if t >= 0.0 {
                    // envelope: raised-cosine bloom, then exponential ring-out
                    let env = if t < attack {
                        0.5 - 0.5 * (PI * t / attack).cos()
                    } else {
                        (-(t - attack) / decay).exp()
                    };
                    let trem = 1.0 + td * (2.0 * PI * tr * t).sin();
                    // additive partials, each doubled by a ± detune for a gentle chorus
                    let mut osc = 0.0;
                    let mut sw = 0.0;
                    for p in 1..=bright {
                        let w = 1.0 / (p as f32).powf(1.3);
                        let f = note.freq * p as f32;
                        osc += w * (2.0 * PI * f * (1.0 - det) * t).sin();
                        osc += w * (2.0 * PI * f * (1.0 + det) * t).sin();
                        sw += 2.0 * w;
                    }
                    *v += note.amp * env * trem * (osc / sw);
                }
                t += dt;
            }
            note.t = t;
            if note.t > end_t {
                note.active = false;
            }
        }

        // --- warmth: one-pole low-pass over the summed cue (stateful across blocks) ---
        let a = (-2.0 * PI * self.cfg.warmth_hz / self.sr).exp();
        let b = 1.0 - a;
        for v in out.iter_mut().take(frames) {
            self.lp_state = b * *v + a * self.lp_state;
            *v = self.lp_state;
        }
    }
}
