//! A single spatialized voice: distance/air-absorption shaping of the mono input,
//! an ITD fractional delay per ear, and a minimum-phase HRIR FIR per ear. HRIR
//! coefficients and the ITD are ramped across the block so motion is click-free.

/// Fractional delay line (linear interpolation). Length rounded up to a power of two.
pub struct DelayLine {
    buf: Vec<f32>,
    mask: usize,
    w: usize,
}

impl DelayLine {
    pub fn new(max_delay: usize) -> DelayLine {
        let cap = (max_delay + 4).next_power_of_two();
        DelayLine {
            buf: vec![0.0; cap],
            mask: cap - 1,
            w: 0,
        }
    }
    pub fn clear(&mut self) {
        for v in &mut self.buf {
            *v = 0.0;
        }
    }
    #[inline]
    pub fn push(&mut self, x: f32) {
        self.buf[self.w] = x;
        self.w = (self.w + 1) & self.mask;
    }
    /// Read the sample `delay` (fractional, in samples) behind the most recent push.
    #[inline]
    pub fn read(&self, delay: f32) -> f32 {
        let d = delay.max(0.0);
        let i = d.floor() as usize;
        let frac = d - i as f32;
        // most recent pushed sample is at (w-1)
        let a = self.buf[(self.w.wrapping_sub(1).wrapping_sub(i)) & self.mask];
        let b = self.buf[(self.w.wrapping_sub(2).wrapping_sub(i)) & self.mask];
        a + (b - a) * frac
    }
}

/// Sparse velvet-noise FIR decorrelator: 16 signed taps over `span` samples with
/// exponentially decaying magnitudes, normalized to unit energy. Used to decorrelate the
/// satellite taps of a volumetric (extent > 0) source from each other and from the centre
/// voice. Pure FIR (no feedback) so it is denormal-safe, and the tap positions are integer
/// samples from a fixed LCG seed, so it is deterministic across native/wasm (parity-safe).
pub struct Decorrelator {
    delay: DelayLine,
    taps: [(f32, f32); DECOR_TAPS], // (integer delay in samples, signed gain)
}

const DECOR_TAPS: usize = 16;

impl Decorrelator {
    pub fn new(seed: u32, span: usize) -> Decorrelator {
        let span = span.max(DECOR_TAPS);
        let seg = span as f32 / DECOR_TAPS as f32;
        // exponential magnitude decay, last tap ≈ −12 dB re first (transients stay compact)
        let decay = 0.25f32.powf(1.0 / (DECOR_TAPS as f32 - 1.0));
        let mut s = seed.wrapping_mul(2654435761).wrapping_add(1);
        let mut taps = [(0.0f32, 0.0f32); DECOR_TAPS];
        let mut energy = 0.0f32;
        for (k, t) in taps.iter_mut().enumerate() {
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            let jitter = (s >> 8) as f32 / 16_777_216.0; // [0, 1)
            s = s.wrapping_mul(1664525).wrapping_add(1013904223);
            let sign = if s & 0x10000 != 0 { 1.0 } else { -1.0 };
            let d = (k as f32 * seg + jitter * (seg - 1.0)).floor();
            let g = sign * decay.powi(k as i32);
            energy += g * g;
            *t = (d, g);
        }
        let norm = 1.0 / energy.sqrt();
        for t in &mut taps {
            t.1 *= norm;
        }
        Decorrelator {
            delay: DelayLine::new(span + 4),
            taps,
        }
    }

    pub fn clear(&mut self) {
        self.delay.clear();
    }

    /// Push one input sample and return the decorrelated output.
    #[inline]
    pub fn tick(&mut self, x: f32) -> f32 {
        self.delay.push(x);
        let mut y = 0.0;
        for &(d, g) in &self.taps {
            y += g * self.delay.read(d);
        }
        y
    }
}

/// FIR with per-sample coefficient ramping, SIMD inner loop.
///
/// History is kept in a length-`2L` buffer with every sample written twice (at `wp` and
/// `wp+L`), so the L most recent samples are always a **contiguous** slice — which lets the
/// ramp-and-multiply-accumulate vectorize cleanly. Coefficients are stored **reversed** so
/// the contiguous (chronological) window dots directly against them.
use wide::f32x8;

use crate::dvf::ShelfCoef;

/// Per-ear first-order shelving filter (the near-field DVF), with per-sample coefficient ramping
/// so distance changes are click-free. `y = b0·x + b1·x₋₁ − a1·y₋₁`. Defaults to identity, so a
/// voice that never receives a near-field target is a bit-exact passthrough (far-field unchanged).
struct Shelf1 {
    x1: f32,
    y1: f32,
    b0: f32,
    b1: f32,
    a1: f32,
    b0t: f32,
    b1t: f32,
    a1t: f32,
}

impl Shelf1 {
    fn new() -> Shelf1 {
        Shelf1 { x1: 0.0, y1: 0.0, b0: 1.0, b1: 0.0, a1: 0.0, b0t: 1.0, b1t: 0.0, a1t: 0.0 }
    }
    fn set_target(&mut self, c: ShelfCoef, snap: bool) {
        self.b0t = c.b0;
        self.b1t = c.b1;
        self.a1t = c.a1;
        if snap {
            self.b0 = c.b0;
            self.b1 = c.b1;
            self.a1 = c.a1;
            self.x1 = 0.0;
            self.y1 = 0.0;
        }
    }
    #[inline]
    fn tick(&mut self, x: f32, b0s: f32, b1s: f32, a1s: f32) -> f32 {
        self.b0 += b0s;
        self.b1 += b1s;
        self.a1 += a1s;
        let mut y = self.b0 * x + self.b1 * self.x1 - self.a1 * self.y1;
        if !y.is_finite() {
            y = 0.0;
        }
        self.x1 = x;
        // Flush the feedback state when it decays into the denormal floor (WASM has no FTZ). This
        // never affects a far-field voice (a1 = 0 → no recursion → y already independent of y1).
        self.y1 = if y.abs() < 1.0e-30 { 0.0 } else { y };
        y
    }
}

struct RampFir {
    cur: Vec<f32>,  // reversed coefficients, length L
    targ: Vec<f32>, // reversed target coefficients, length L
    hist: Vec<f32>, // length 2L, duplicated
    wp: usize,      // write position in [0, L)
    len: usize,
}

impl RampFir {
    fn new(len: usize) -> RampFir {
        RampFir {
            cur: vec![0.0; len],
            targ: vec![0.0; len],
            hist: vec![0.0; 2 * len],
            wp: len - 1,
            len,
        }
    }
    fn set_target(&mut self, t: &[f32]) {
        // store reversed: targ[j] = t[L-1-j]
        let l = self.len;
        for j in 0..l {
            self.targ[j] = t[l - 1 - j];
        }
    }
    /// Snap current = target (used on (re)spawn to avoid a ramp from silence).
    fn snap(&mut self) {
        self.cur.copy_from_slice(&self.targ);
    }
    /// Process one sample with a coefficient ramp step `inv_n` (= 1/block_len).
    #[inline]
    fn tick(&mut self, x: f32, inv_n: f32) -> f32 {
        let l = self.len;
        self.wp = if self.wp + 1 == l { 0 } else { self.wp + 1 };
        self.hist[self.wp] = x;
        self.hist[self.wp + l] = x;

        // contiguous chronological window of the L most recent samples
        let win = &self.hist[self.wp + 1..self.wp + 1 + l];
        let cur = &mut self.cur;
        let targ = &self.targ;

        let step = f32x8::splat(inv_n);
        let mut acc = f32x8::splat(0.0);
        let mut j = 0;
        while j + 8 <= l {
            let c = f32x8::from(&cur[j..j + 8]);
            let t = f32x8::from(&targ[j..j + 8]);
            let c2 = c + (t - c) * step;
            c2.as_array_ref().iter().enumerate().for_each(|(k, &v)| cur[j + k] = v);
            let w = f32x8::from(&win[j..j + 8]);
            acc += c2 * w;
            j += 8;
        }
        let mut sum = acc.reduce_add();
        while j < l {
            let c = cur[j] + (targ[j] - cur[j]) * inv_n;
            cur[j] = c;
            sum += c * win[j];
            j += 1;
        }
        sum
    }
}

pub struct Voice {
    pub active: bool,
    fir_l: RampFir,
    fir_r: RampFir,
    delay_l: DelayLine,
    delay_r: DelayLine,
    predelay: DelayLine,
    // smoothed parameters
    gain: f32,
    targ_gain: f32,
    delay_l_cur: f32,
    delay_l_targ: f32,
    delay_r_cur: f32,
    delay_r_targ: f32,
    predelay_cur: f32,
    predelay_targ: f32,
    // one-pole air-absorption lowpass state + coeff
    lp_state: f32,
    lp_a: f32,
    // per-ear near-field DVF shelf (identity unless a near-field target is set)
    shelf_l: Shelf1,
    shelf_r: Shelf1,
}

impl Voice {
    pub fn new(hrir_len: usize, max_itd: usize, max_predelay: usize) -> Voice {
        Voice {
            active: false,
            fir_l: RampFir::new(hrir_len),
            fir_r: RampFir::new(hrir_len),
            delay_l: DelayLine::new(max_itd),
            delay_r: DelayLine::new(max_itd),
            predelay: DelayLine::new(max_predelay.max(1)),
            gain: 0.0,
            targ_gain: 0.0,
            delay_l_cur: 0.0,
            delay_l_targ: 0.0,
            delay_r_cur: 0.0,
            delay_r_targ: 0.0,
            predelay_cur: 0.0,
            predelay_targ: 0.0,
            lp_state: 0.0,
            lp_a: 1.0,
            shelf_l: Shelf1::new(),
            shelf_r: Shelf1::new(),
        }
    }

    /// Set the per-ear near-field DVF shelves. Only the direct path calls this; reflection voices
    /// leave the shelves at identity. Snaps on (re)spawn to avoid a ramp from the identity state.
    pub fn set_dvf(&mut self, l: ShelfCoef, r: ShelfCoef, snap: bool) {
        let s = snap || !self.active;
        self.shelf_l.set_target(l, s);
        self.shelf_r.set_target(r, s);
    }

    pub fn reset(&mut self) {
        self.fir_l.hist.iter_mut().for_each(|v| *v = 0.0);
        self.fir_r.hist.iter_mut().for_each(|v| *v = 0.0);
        self.delay_l.clear();
        self.delay_r.clear();
        self.predelay.clear();
        self.lp_state = 0.0;
        self.gain = 0.0;
        self.shelf_l.x1 = 0.0;
        self.shelf_l.y1 = 0.0;
        self.shelf_r.x1 = 0.0;
        self.shelf_r.y1 = 0.0;
    }

    /// Set per-block targets. `itd > 0` delays the right ear (source toward left).
    /// `lp_a` is the one-pole air-absorption coefficient (1.0 = no filtering).
    /// `predelay` is an extra propagation delay in samples (0 for the direct path).
    pub fn set_target(
        &mut self,
        hrir_l: &[f32],
        hrir_r: &[f32],
        itd: f32,
        gain: f32,
        lp_a: f32,
        predelay: f32,
        snap: bool,
    ) {
        self.fir_l.set_target(hrir_l);
        self.fir_r.set_target(hrir_r);
        let (dl, dr) = if itd >= 0.0 { (0.0, itd) } else { (-itd, 0.0) };
        self.delay_l_targ = dl;
        self.delay_r_targ = dr;
        self.targ_gain = gain;
        self.lp_a = lp_a;
        self.predelay_targ = predelay;
        if snap || !self.active {
            self.fir_l.snap();
            self.fir_r.snap();
            self.delay_l_cur = dl;
            self.delay_r_cur = dr;
            self.predelay_cur = predelay;
            self.gain = gain;
        }
        self.active = true;
    }

    /// Render `inp` into the stereo direct bus and accumulate the (post-distance)
    /// mono signal into `send` scaled by `send_gain`. Returns nothing.
    pub fn process(
        &mut self,
        inp: &[f32],
        out_l: &mut [f32],
        out_r: &mut [f32],
        send: &mut [f32],
        send_gain: f32,
    ) {
        let n = inp.len();
        if n == 0 {
            return;
        }
        let inv_n = 1.0 / n as f32;
        let g_step = (self.targ_gain - self.gain) * inv_n;
        let dl_step = (self.delay_l_targ - self.delay_l_cur) * inv_n;
        let dr_step = (self.delay_r_targ - self.delay_r_cur) * inv_n;
        let pd_step = (self.predelay_targ - self.predelay_cur) * inv_n;
        // per-ear near-field shelf coefficient ramp (identity → identity is a no-op)
        let lb0 = (self.shelf_l.b0t - self.shelf_l.b0) * inv_n;
        let lb1 = (self.shelf_l.b1t - self.shelf_l.b1) * inv_n;
        let la1 = (self.shelf_l.a1t - self.shelf_l.a1) * inv_n;
        let rb0 = (self.shelf_r.b0t - self.shelf_r.b0) * inv_n;
        let rb1 = (self.shelf_r.b1t - self.shelf_r.b1) * inv_n;
        let ra1 = (self.shelf_r.a1t - self.shelf_r.a1) * inv_n;

        for i in 0..n {
            // distance gain ramp + air-absorption one-pole LP (+ denormal flush: WASM has
            // no flush-to-zero, so a decaying IIR tail can fall into denormals -> CPU spikes
            // and crackle). Sanitize the input + self-heal the IIR state: a stray NaN must
            // not lock this one-pole dead forever (it would silence the whole voice).
            self.gain += g_step;
            let xin = if inp[i].is_finite() { inp[i] } else { 0.0 };
            let pre = xin * self.gain;
            self.lp_state += self.lp_a * (pre - self.lp_state) + 1.0e-20;
            if !self.lp_state.is_finite() {
                self.lp_state = 0.0;
            }
            let lp = self.lp_state;

            // propagation pre-delay (0 for direct path, path length for reflections)
            self.predelay.push(lp);
            self.predelay_cur += pd_step;
            let dry = self.predelay.read(self.predelay_cur);

            // feed both ear delay lines with the dry mono, read fractional ITD
            self.delay_l.push(dry);
            self.delay_r.push(dry);
            self.delay_l_cur += dl_step;
            self.delay_r_cur += dr_step;
            let xl = self.delay_l.read(self.delay_l_cur);
            let xr = self.delay_r.read(self.delay_r_cur);

            // near-field DVF: per-ear shelf on top of the far-field HRIR (H_far · DVF ≈ H_near).
            // Identity for far-field voices, so this is a passthrough outside ~1 m.
            let xl = self.shelf_l.tick(xl, lb0, lb1, la1);
            let xr = self.shelf_r.tick(xr, rb0, rb1, ra1);

            out_l[i] += self.fir_l.tick(xl, inv_n);
            out_r[i] += self.fir_r.tick(xr, inv_n);

            send[i] += dry * send_gain;
        }
    }
}
