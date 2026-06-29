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

/// FIR with per-sample coefficient ramping toward a target tap set.
struct RampFir {
    cur: Vec<f32>,
    targ: Vec<f32>,
    hist: Vec<f32>, // ring of past inputs
    mask: usize,
    w: usize,
    len: usize,
}

impl RampFir {
    fn new(len: usize) -> RampFir {
        let cap = len.next_power_of_two();
        RampFir {
            cur: vec![0.0; len],
            targ: vec![0.0; len],
            hist: vec![0.0; cap],
            mask: cap - 1,
            w: 0,
            len,
        }
    }
    fn set_target(&mut self, t: &[f32]) {
        self.targ.copy_from_slice(t);
    }
    /// Snap current = target (used on (re)spawn to avoid a ramp from silence).
    fn snap(&mut self) {
        self.cur.copy_from_slice(&self.targ);
    }
    /// Process one sample with a coefficient ramp step `inv_n` (= 1/block_len).
    #[inline]
    fn tick(&mut self, x: f32, inv_n: f32) -> f32 {
        // advance the newest input
        self.hist[self.w] = x;
        let w = self.w;
        self.w = (self.w + 1) & self.mask;

        let mut acc = 0.0f32;
        let cur = &mut self.cur;
        let targ = &self.targ;
        let hist = &self.hist;
        let mask = self.mask;
        for k in 0..self.len {
            // ramp this coefficient a fraction of the way to target
            let c = cur[k] + (targ[k] - cur[k]) * inv_n;
            cur[k] = c;
            let h = hist[(w.wrapping_sub(k)) & mask];
            acc += c * h;
        }
        acc
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
        }
    }

    pub fn reset(&mut self) {
        self.fir_l.hist.iter_mut().for_each(|v| *v = 0.0);
        self.fir_r.hist.iter_mut().for_each(|v| *v = 0.0);
        self.delay_l.clear();
        self.delay_r.clear();
        self.predelay.clear();
        self.lp_state = 0.0;
        self.gain = 0.0;
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

        for i in 0..n {
            // distance gain ramp + air-absorption one-pole LP
            self.gain += g_step;
            let pre = inp[i] * self.gain;
            self.lp_state += self.lp_a * (pre - self.lp_state);
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

            out_l[i] += self.fir_l.tick(xl, inv_n);
            out_r[i] += self.fir_r.tick(xr, inv_n);

            send[i] += dry * send_gain;
        }
    }
}
