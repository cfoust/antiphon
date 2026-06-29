//! Parametric late reverberation: a 16-line feedback delay network (FDN) with a
//! Hadamard mixing matrix and per-line damping. Mono send in, decorrelated stereo out.
//!
//! Self-contained (no measured IR needed) and cheap, which makes it the default room
//! backend. The convolution (BRIR) backend is a separate `ReverbBackend` and can be
//! swapped in per preset; both feed the same reverb bus.

const LINES: usize = 16;

// Base prime-ish delay lengths (samples @48k) — mutually staggered for echo density.
// Scaled by room size at configure time.
const BASE_DELAYS: [usize; LINES] = [
    1153, 1327, 1559, 1801, 2099, 2341, 2593, 2803, 3079, 3331, 3571, 3803, 4051, 4297, 4549, 4801,
];

const ANTI_DENORMAL: f32 = 1.0e-20;

pub struct Fdn {
    lines: Vec<Vec<f32>>,
    read: Vec<usize>,
    len: Vec<usize>,
    fb_gain: Vec<f32>,
    damp_state: Vec<f32>,
    damp_a: f32,
    out_sign_l: [f32; LINES],
    out_sign_r: [f32; LINES],
    wet: f32,
    sr: f32,
}

impl Fdn {
    pub fn new(sr: f32) -> Fdn {
        let max = *BASE_DELAYS.iter().max().unwrap() * 2 + 8;
        let mut lines = Vec::with_capacity(LINES);
        for _ in 0..LINES {
            lines.push(vec![0.0f32; max]);
        }
        // Decorrelation pattern for stereo output taps.
        let mut sgl = [0.0f32; LINES];
        let mut sgr = [0.0f32; LINES];
        for i in 0..LINES {
            let s = if i % 2 == 0 { 1.0 } else { -1.0 };
            sgl[i] = s;
            sgr[i] = if (i / 2) % 2 == 0 { s } else { -s };
        }
        Fdn {
            lines,
            read: vec![0; LINES],
            len: BASE_DELAYS.to_vec(),
            fb_gain: vec![0.0; LINES],
            damp_state: vec![0.0; LINES],
            damp_a: 0.5,
            out_sign_l: sgl,
            out_sign_r: sgr,
            wet: 0.3,
            sr,
        }
    }

    /// Configure from a room preset. `size` ~ mean room dimension in metres.
    pub fn configure(&mut self, rt60_mid: f32, rt60_high: f32, size: f32, wet: f32) {
        self.wet = wet;
        let scale = (size / 8.0).clamp(0.35, 3.0);
        let max = self.lines[0].len();
        for i in 0..LINES {
            let l = ((BASE_DELAYS[i] as f32) * scale) as usize;
            self.len[i] = l.clamp(64, max - 4);
            let dsec = self.len[i] as f32 / self.sr;
            // feedback gain for the target mid-band RT60
            let rt = rt60_mid.max(0.05);
            self.fb_gain[i] = 10f32.powf(-3.0 * dsec / rt);
        }
        // HF damping: ratio of high to mid decay sets the lowpass in the loop.
        let ratio = (rt60_high.max(0.05) / rt60_mid.max(0.05)).clamp(0.05, 1.0);
        // smaller ratio -> more HF damping -> smaller damp_a
        self.damp_a = (0.15 + 0.8 * ratio).clamp(0.05, 0.999);
    }

    pub fn reset(&mut self) {
        for l in &mut self.lines {
            l.iter_mut().for_each(|v| *v = 0.0);
        }
        self.damp_state.iter_mut().for_each(|v| *v = 0.0);
        self.read.iter_mut().for_each(|v| *v = 0);
    }

    /// Process a mono send block, adding wet stereo into `out_l`/`out_r`.
    pub fn process(&mut self, send: &[f32], out_l: &mut [f32], out_r: &mut [f32]) {
        let n = send.len();
        let in_gain = 1.0 / (LINES as f32).sqrt();
        for s in 0..n {
            let x = send[s];
            // read taps
            let mut v = [0.0f32; LINES];
            for i in 0..LINES {
                let r = self.read[i];
                v[i] = self.lines[i][r];
            }
            // output: decorrelated sum
            let mut ol = 0.0f32;
            let mut or = 0.0f32;
            for i in 0..LINES {
                ol += v[i] * self.out_sign_l[i];
                or += v[i] * self.out_sign_r[i];
            }
            let og = self.wet / (LINES as f32).sqrt();
            out_l[s] += ol * og;
            out_r[s] += or * og;

            // mix (Hadamard), damp, apply feedback gain, inject input
            hadamard16(&mut v);
            for i in 0..LINES {
                // per-line one-pole lowpass (damping)
                let damped = self.damp_state[i] + self.damp_a * (v[i] - self.damp_state[i]);
                self.damp_state[i] = damped;
                let fb = damped * self.fb_gain[i];
                let write = self.read[i]; // we overwrite the slot we just read
                self.lines[i][write] = fb + x * in_gain + ANTI_DENORMAL;
                self.read[i] = if write + 1 >= self.len[i] {
                    0
                } else {
                    write + 1
                };
            }
        }
    }
}

/// Tier-1 convolution reverb: convolves the mono send against a measured/synthesized
/// stereo late-BRIR using uniformly-partitioned FFT convolution (real-time safe, no
/// allocation in `process`). A BRIR is captured at the eardrums, so this is binaural by
/// construction — no extra HRTF on the tail.
pub struct ConvReverb {
    cl: fft_convolver::FFTConvolver<f32>,
    cr: fft_convolver::FFTConvolver<f32>,
    tmp_l: Vec<f32>,
    tmp_r: Vec<f32>,
    wet: f32,
}

impl ConvReverb {
    /// `partition` is the FFT block size (use the audio block, e.g. 128). `max_block`
    /// sizes the scratch so `process` never allocates.
    pub fn new(partition: usize, ir_l: &[f32], ir_r: &[f32], wet: f32, max_block: usize) -> ConvReverb {
        let mut cl = fft_convolver::FFTConvolver::default();
        let mut cr = fft_convolver::FFTConvolver::default();
        let _ = cl.init(partition, ir_l);
        let _ = cr.init(partition, ir_r);
        ConvReverb {
            cl,
            cr,
            tmp_l: vec![0.0; max_block],
            tmp_r: vec![0.0; max_block],
            wet,
        }
    }

    pub fn process(&mut self, send: &[f32], out_l: &mut [f32], out_r: &mut [f32]) {
        let n = send.len();
        let tl = &mut self.tmp_l[..n];
        let tr = &mut self.tmp_r[..n];
        let _ = self.cl.process(send, tl);
        let _ = self.cr.process(send, tr);
        let w = self.wet;
        for i in 0..n {
            out_l[i] += w * tl[i];
            out_r[i] += w * tr[i];
        }
    }
}

/// In-place 16-point Walsh-Hadamard transform, scaled to be orthonormal (×1/4).
#[inline]
fn hadamard16(v: &mut [f32; 16]) {
    let mut h = 1;
    while h < 16 {
        let mut i = 0;
        while i < 16 {
            for j in i..i + h {
                let a = v[j];
                let b = v[j + h];
                v[j] = a + b;
                v[j + h] = a - b;
            }
            i += h * 2;
        }
        h *= 2;
    }
    let s = 0.25; // 1/sqrt(16)
    for x in v.iter_mut() {
        *x *= s;
    }
}
