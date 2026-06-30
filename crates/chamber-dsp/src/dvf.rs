//! Near-field HRTF correction via a Distance Variation Function (DVF).
//!
//! Generic far-field HRIRs are wrong for a source inside ~1 m: the interaural level difference
//! grows dramatically and mostly at LOW frequency, because the wavefront curvature plus the `1/r`
//! falloff across the head's width make the near ear much louder than the far ear even where the
//! head casts no high-frequency shadow (Brungart & Rabinowitz; Duda & Martens). The ITD stays
//! ~range-independent, so the existing per-ear delay needs no change — only a per-ear spectral
//! correction. We apply a first-order shelving filter per ear on top of the baked far-field HRIR;
//! cascaded, `H_far · DVF ≈ H_near`.
//!
//! The shelf is the parametric rigid-sphere fit of Spagnol, Tavazzi & Avanzini, "Distance
//! rendering and perception of nearby virtual sound sources with a near-field filter model,"
//! Applied Acoustics 115:61–73 (2017), ported from S. J. Schlecht's reference MATLAB
//! (github.com/SebastianJiroSchlecht/NearFieldModel). The coefficients are rational fits in the
//! incidence angle and normalized distance, evaluated **once per block in the control path**; the
//! audio path is a trivial first-order IIR (mul/add only). Deterministic math → native↔wasm
//! parity-safe. Gated to identity for `r ≥ ~1 m` so far-field renders are unchanged.

use core::f64::consts::PI;

/// First-order shelf coefficients: `y = b0·x + b1·x₋₁ − a1·y₋₁`.
#[derive(Clone, Copy)]
pub struct ShelfCoef {
    pub b0: f32,
    pub b1: f32,
    pub a1: f32,
}

impl ShelfCoef {
    pub const IDENTITY: ShelfCoef = ShelfCoef { b0: 1.0, b1: 0.0, a1: 0.0 };
}

const A: f64 = 0.0875; // head radius (m); a_0 = a so the warping factor a_0/a is 1
const C: f64 = 343.0; // speed of sound (m/s)
const RHO_GATE: f64 = 11.43; // r/a at ~1 m: at/above this the DVF is identity (far field)
const RHO_FADE: f64 = 9.0; // below this, full effect; (RHO_FADE, RHO_GATE) fades to identity

/// Spagnol Table 1, rows at `alpha = 0,10,…,180°`. Columns (the leading alpha is implicit in the
/// row index): p11, p21, q11, q21, p12, p22, q12, q22, p13, p23, p33, q13, q23.
#[rustfmt::skip]
const TABLE: [[f64; 13]; 19] = [
    [ 12.97,  -9.69, -1.14,  0.219, -4.39,  2.123, -0.55, -0.06,  0.457,  -0.67,  0.174, -1.75,  0.699],
    [ 13.19, 234.2,  18.48, -8.5,   -4.31, -2.78,   0.59, -0.17,  0.455,   0.142,-0.11,  -0.01, -0.35 ],
    [ 12.13, -11.2,  -1.25,  0.346, -4.18,  4.224, -1.01, -0.02, -0.87, 3404.0, -1699.0,7354.0,-5350.0],
    [ 11.19,  -9.03, -1.02,  0.336, -4.01,  3.039, -0.56, -0.32,  0.465,  -0.91,  0.437, -2.18,  1.188],
    [  9.91,  -7.87, -0.83,  0.379, -3.87, -0.57,   0.665,-1.13,  0.494,  -0.67,  0.658, -1.2,   0.256],
    [  8.328, -7.42, -0.67,  0.421, -4.1, -34.7,   11.39, -8.3,   0.549,  -1.21,  2.02,  -1.59,  0.816],
    [  6.493, -7.31, -0.5,   0.423, -3.87,  3.271, -1.57,  0.637, 0.663,  -1.76,  6.815, -1.23,  1.166],
    [  4.455, -7.28, -0.32,  0.382, -5.02,  0.023, -0.87,  0.325, 0.691,   4.655, 0.614, -0.89,  0.76 ],
    [  2.274, -7.29, -0.11,  0.314, -6.72, -8.96,   0.37, -0.08,  3.507,  55.09,589.3,  29.23, 59.51 ],
    [  0.018, -7.48, -0.13,  0.24,  -8.69,-58.4,    5.446,-1.19, -27.4,10336.0,16818.0,1945.0,1707.0 ],
    [ -2.24,  -8.04,  0.395, 0.177,-11.2,  11.47,  -1.13,  0.103, 6.371,   1.735,-9.39,  -0.06, -1.12 ],
    [ -4.43,  -9.23,  0.699, 0.132,-12.1,   8.716, -0.63, -0.12,  7.032,  40.88,-44.1,   5.635, -6.18 ],
    [ -6.49, -11.6,   1.084, 0.113,-11.1,  21.8,   -2.01,  0.098, 7.092,  23.86,-23.6,   3.308, -3.39 ],
    [ -8.34, -17.4,   1.757, 0.142,-11.1,   1.91,   0.15, -0.4,   7.463, 102.8,-92.3,   13.88, -12.7 ],
    [ -9.93, -48.4,   4.764, 0.462, -9.72, -0.04,   0.243,-0.41,  7.453,  -6.14,-1.81,  -0.88,  -0.19 ],
    [-11.3,   9.149, -0.64, -0.14,  -8.42, -0.66,   0.147,-0.34,  8.101, -18.1, 10.54,  -2.23,   1.295],
    [-12.2,   1.905,  0.109,-0.08,  -7.44,  0.395, -0.18, -0.18,  8.702,  -9.05, 0.532, -0.96,  -0.02 ],
    [-12.8,  -0.75,   0.386,-0.06,  -6.78,  2.662, -0.67,  0.05,  8.925,  -9.03, 0.285, -0.9,   -0.08 ],
    [-13.0,  -1.32,   0.45, -0.05,  -6.58,  3.387, -0.84,  0.131, 9.317,  -6.89,-2.08,  -0.57,  -0.4  ],
];

#[inline]
fn db2mag(db: f64) -> f64 {
    10f64.powf(db / 20.0)
}

/// Per-ear near-field shelf for incidence angle `alpha_deg` (0 = ipsilateral … 180 =
/// contralateral) and normalized distance `rho = r / a`, at sample rate `fs`. Returns identity for
/// `r ≥ ~1 m`, so far-field rendering is untouched.
pub fn near_field_shelf(alpha_deg: f32, rho: f32, fs: f32) -> ShelfCoef {
    let rho = rho as f64;
    if rho >= RHO_GATE {
        return ShelfCoef::IDENTITY;
    }
    let rho_c = rho.max(1.25); // the model is fit/clipped for rho ≥ 1.25
    let theta = (alpha_deg as f64).abs().clamp(0.0, 180.0);

    // bracketing rows on the 10° alpha grid, then linear interpolate the three shelf params
    let fi = theta / 10.0;
    let i0 = (fi.floor() as usize).min(17);
    let fr = fi - i0 as f64;

    let eval = |r: &[f64; 13]| -> (f64, f64, f64) {
        // Eqs (8), (13), (14): G_0 and G_inf in dB, f_c normalized (then denormalized to Hz).
        let g0 = (r[0] * rho_c + r[1]) / (rho_c * rho_c + r[2] * rho_c + r[3]);
        let ginf = (r[4] * rho_c + r[5]) / (rho_c * rho_c + r[6] * rho_c + r[7]);
        let fcn = (r[8] * rho_c * rho_c + r[9] * rho_c + r[10]) / (rho_c * rho_c + r[11] * rho_c + r[12]);
        (g0, ginf, fcn * C / (2.0 * PI * A))
    };
    let (g0a, ginfa, fca) = eval(&TABLE[i0]);
    let (g0b, ginfb, fcb) = eval(&TABLE[i0 + 1]);
    let g0 = g0a + (g0b - g0a) * fr;
    let ginf = ginfa + (ginfb - ginfa) * fr;
    let fc = fca + (fcb - fca) * fr;

    // First-order shelving realization (Eqs 10–12). DC gain = G_0 dB, Nyquist gain = G_0 + G_inf.
    let v0 = db2mag(ginf);
    let tan_f = (PI * fc / fs as f64).tan();
    let a_c = (v0 * tan_f - 1.0) / (v0 * tan_f + 1.0);
    let v = (v0 - 1.0) / 2.0;
    let gain = db2mag(g0);
    let (mut b0, mut b1, mut a1) = (gain * (v * (1.0 - a_c) + 1.0), gain * (v * (a_c - 1.0) + a_c), a_c);

    // Fade to identity across (RHO_FADE, RHO_GATE) so crossing the far-field gate is click-free.
    let f = ((RHO_GATE - rho) / (RHO_GATE - RHO_FADE)).clamp(0.0, 1.0);
    b0 = f * b0 + (1.0 - f);
    b1 *= f;
    a1 *= f;

    ShelfCoef { b0: b0 as f32, b1: b1 as f32, a1: a1 as f32 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn far_field_is_identity() {
        // r >= ~1 m must return exact identity so far-field renders are unchanged.
        let c = near_field_shelf(0.0, 12.0, 48000.0);
        assert_eq!((c.b0, c.b1, c.a1), (1.0, 0.0, 0.0));
    }

    #[test]
    fn near_ear_boosts_far_ear_cuts_low_end() {
        // At ~12 cm (rho ~1.4), the ipsilateral ear gets a low-frequency boost and the
        // contralateral ear a cut — the defining near-field ILD growth.
        let near = near_field_shelf(0.0, 1.4, 48000.0); // DC gain = b0+b1 over 1+a1
        let far = near_field_shelf(180.0, 1.4, 48000.0);
        let dc = |c: ShelfCoef| (c.b0 + c.b1) / (1.0 + c.a1);
        assert!(dc(near) > 1.5, "near-ear DC gain {} should boost", dc(near));
        assert!(dc(far) < 0.8, "far-ear DC gain {} should cut", dc(far));
    }
}
