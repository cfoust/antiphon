//! Runtime HRTF database: interpolates a minimum-phase HRIR pair + ITD for any
//! listener-relative direction from the discrete grid stored in the asset.
//!
//! Interpolation is inverse-angular-distance weighting over the K nearest measured
//! directions (K=3). Because the stored HRIRs are minimum-phase, their taps can be
//! blended linearly without comb-filtering; the ITD is blended as a scalar and applied
//! separately as a fractional delay in [`crate::voice`].

use crate::math::Vec3;
use antiphon_assets::AntiphonAsset;
use core::f32::consts::PI;

const K: usize = 3;

// ---- Diffuse-field equalization (DFE) ----------------------------------------------------------
// A generic (non-individual) HRTF set carries an average, direction-INDEPENDENT spectral
// coloration — the "common transfer function" — that makes every source sound like the same
// colored loudspeaker. We estimate the diffuse-field magnitude (RMS over ALL directions AND
// both ears, so no left/right bias is introduced) and divide every stored HRIR by a gentle,
// log-frequency-smoothed version of it. What remains is mostly the direction-DEPENDENT cues, so
// the residual timbre reads more like a neutral voice and less like a speaker. Done once at load
// (off the audio path); deterministic across native/wasm (same scalar f32 math both targets).

/// Fractional-octave width of the smoothing applied to the diffuse-field curve before inversion.
/// Wide enough that we flatten the broad coloration but never try to fill sharp pinna notches.
const DFE_SMOOTH_OCT: f32 = 0.5;
/// Hard clamp on the correction (dB), so a deep notch in the estimate can't become a huge boost.
const DFE_MAX_DB: f32 = 8.0;
/// Overall strength of the correction (1.0 = full inverse of the smoothed diffuse field).
const DFE_STRENGTH: f32 = 1.0;

/// Flatten the common (direction-independent) spectral envelope out of every stored HRIR.
/// Operates in place on the flattened `left`/`right` tap arrays (`num_dirs * n` each).
fn diffuse_field_eq(left: &mut [f32], right: &mut [f32], n: usize, sr: f32) {
    let num = if n > 0 { left.len() / n } else { 0 };
    if num == 0 || n < 8 {
        return;
    }
    let half = n / 2;

    // Precompute DFT twiddles: cs/sn are cos/sin of the FORWARD angle -2πkj/n.
    let mut cs = vec![0.0f32; n * n];
    let mut sn = vec![0.0f32; n * n];
    for k in 0..n {
        for j in 0..n {
            let ang = -2.0 * PI * (k as f32) * (j as f32) / n as f32;
            cs[k * n + j] = ang.cos();
            sn[k * n + j] = ang.sin();
        }
    }

    // Pass 1: accumulate diffuse-field power per bin over all directions and both ears.
    let mut dpow = vec![0.0f64; half + 1];
    let bin_mag2 = |x: &[f32], k: usize| -> f32 {
        let base = k * n;
        let mut re = 0.0f32;
        let mut im = 0.0f32;
        for j in 0..n {
            re += x[j] * cs[base + j];
            im += x[j] * sn[base + j];
        }
        re * re + im * im
    };
    for d in 0..num {
        let lo = &left[d * n..d * n + n];
        let ro = &right[d * n..d * n + n];
        for k in 0..=half {
            dpow[k] += bin_mag2(lo, k) as f64 + bin_mag2(ro, k) as f64;
        }
    }
    let inv_cnt = 1.0 / (2 * num) as f64;
    let mut dmag = vec![0.0f32; half + 1];
    for k in 0..=half {
        dmag[k] = ((dpow[k] * inv_cnt).max(0.0)).sqrt() as f32;
    }

    // Log-frequency smoothing of the diffuse-field magnitude (RMS within a fractional-octave box).
    let span = 2f32.powf(DFE_SMOOTH_OCT * 0.5);
    let mut dsm = vec![0.0f32; half + 1];
    for k in 0..=half {
        let lo = ((k as f32) / span).floor() as usize;
        let hi = (((k as f32) * span).ceil() as usize).min(half);
        let lo = lo.min(hi);
        let mut acc = 0.0f32;
        let mut c = 0u32;
        for j in lo..=hi {
            acc += dmag[j] * dmag[j];
            c += 1;
        }
        dsm[k] = if c > 0 { (acc / c as f32).sqrt() } else { dmag[k] };
    }

    // Reference level: geometric mean of the smoothed curve across the speech band, so the
    // correction reshapes timbre WITHOUT changing broadband loudness.
    let bin_of = |f: f32| ((f * n as f32 / sr).round() as usize).clamp(1, half);
    let blo = bin_of(200.0);
    let bhi = bin_of(8000.0).max(blo);
    let mut logsum = 0.0f32;
    let mut c = 0u32;
    for k in blo..=bhi {
        if dsm[k] > 1e-9 {
            logsum += dsm[k].ln();
            c += 1;
        }
    }
    let dref = if c > 0 { (logsum / c as f32).exp() } else { 1.0 };

    // Inverse-EQ gain per bin (log domain: clamp, taper LF to unity, apply strength).
    let lim = (DFE_MAX_DB / 20.0) * core::f32::consts::LN_10; // ±dB in natural log
    let mut g = vec![1.0f32; half + 1];
    for k in 0..=half {
        let raw = if dsm[k] > 1e-9 { dref / dsm[k] } else { 1.0 };
        let f = k as f32 * sr / n as f32;
        let taper = (f / 150.0).clamp(0.0, 1.0); // no large sub-150 Hz boost
        let l = raw.max(1e-6).ln().clamp(-lim, lim) * taper * DFE_STRENGTH;
        g[k] = l.exp();
    }
    // Symmetric gain over the full spectrum.
    let mut gsym = vec![1.0f32; n];
    for k in 0..n {
        gsym[k] = g[if k <= half { k } else { n - k }];
    }

    // Pass 2: apply the gain (magnitude-only; phase preserved) to every HRIR via DFT/IDFT.
    let mut re = vec![0.0f32; n];
    let mut im = vec![0.0f32; n];
    let inv = 1.0 / n as f32;
    let mut apply = |hrir: &mut [f32]| {
        for k in 0..n {
            let base = k * n;
            let mut r = 0.0f32;
            let mut iv = 0.0f32;
            for j in 0..n {
                r += hrir[j] * cs[base + j];
                iv += hrir[j] * sn[base + j];
            }
            re[k] = r * gsym[k];
            im[k] = iv * gsym[k];
        }
        for j in 0..n {
            let mut acc = 0.0f32;
            for k in 0..n {
                acc += re[k] * cs[k * n + j] + im[k] * sn[k * n + j];
            }
            hrir[j] = acc * inv;
        }
    };
    for d in 0..num {
        apply(&mut left[d * n..d * n + n]);
        apply(&mut right[d * n..d * n + n]);
    }
}

pub struct HrtfDb {
    pub hrir_len: usize,
    units: Vec<Vec3>,
    itd: Vec<f32>,
    left: Vec<f32>,  // num_dirs * hrir_len
    right: Vec<f32>, // num_dirs * hrir_len
}

impl HrtfDb {
    pub fn from_asset(a: &AntiphonAsset) -> HrtfDb {
        let units = a
            .directions
            .iter()
            .map(|d| Vec3::new(d.unit[0], d.unit[1], d.unit[2]))
            .collect();
        let itd = a.directions.iter().map(|d| d.itd).collect();
        let mut left = a.hrir_left.clone();
        let mut right = a.hrir_right.clone();
        // Diffuse-field equalization: flatten the common (direction-independent) spectral
        // coloration out of the generic HRTF set so what remains is mostly directional cues.
        // ON by default; applied once here, off the audio path.
        diffuse_field_eq(&mut left, &mut right, a.hrir_len, a.sample_rate);
        HrtfDb {
            hrir_len: a.hrir_len,
            units,
            itd,
            left,
            right,
        }
    }

    pub fn num_dirs(&self) -> usize {
        self.units.len()
    }

    /// Find the K nearest measured directions to `dir` and their inverse-angle weights.
    fn nearest(&self, dir: Vec3) -> ([(f32, usize); K], [f32; K]) {
        let mut best: [(f32, usize); K] = [(-2.0, 0); K];
        for (i, u) in self.units.iter().enumerate() {
            let d = dir.dot(*u);
            if d > best[K - 1].0 {
                let mut j = K - 1;
                while j > 0 && d > best[j - 1].0 {
                    best[j] = best[j - 1];
                    j -= 1;
                }
                best[j] = (d, i);
            }
        }
        let mut w = [0.0f32; K];
        let mut wsum = 0.0f32;
        for k in 0..K {
            let dot = best[k].0.clamp(-1.0, 1.0);
            let wk = 1.0 / (dot.acos() + 1e-3);
            w[k] = wk;
            wsum += wk;
        }
        let inv = 1.0 / wsum;
        for k in 0..K {
            w[k] *= inv;
        }
        (best, w)
    }

    /// Interpolate the HRIR pair for `dir` into `left`/`right` (each `hrir_len` long)
    /// and return the blended ITD in fractional samples.
    pub fn interp(&self, dir: Vec3, left: &mut [f32], right: &mut [f32]) -> f32 {
        debug_assert!(!self.units.is_empty());
        let (best, w) = self.nearest(dir);
        let l = self.hrir_len;
        for t in 0..l {
            left[t] = 0.0;
            right[t] = 0.0;
        }
        let mut itd = 0.0f32;
        for k in 0..K {
            let wk = w[k];
            let idx = best[k].1;
            let base = idx * l;
            let ls = &self.left[base..base + l];
            let rs = &self.right[base..base + l];
            for t in 0..l {
                left[t] += wk * ls[t];
                right[t] += wk * rs[t];
            }
            itd += wk * self.itd[idx];
        }
        itd
    }
}
