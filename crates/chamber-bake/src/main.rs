//! Offline asset baker.
//!
//! Produces a `.chamber` blob containing a spherical HRTF grid (minimum-phase HRIR
//! pairs + Woodworth ITD) and a set of parametric room presets.
//!
//! The HRTF here is a self-contained *structural* model — frequency-dependent head
//! shadow (ILD), an elevation-dependent pinna notch, and a spherical-head ITD — so a
//! usable, fully 3D HRTF exists with zero external downloads. The engine consumes the
//! grid identically regardless of whether it came from this model or a measured SOFA
//! set, so a SOFA importer can be dropped in later behind the same `--sofa` flag.
//!
//! Usage: chamber-bake [out.chamber]

use chamber_assets::{AssetBuilder, ReverbBackend, RoomPreset};
use rustfft::{num_complex::Complex, FftPlanner};
use std::f32::consts::PI;

const SR: f32 = 48_000.0;
const HRIR_LEN: usize = 128;
const FFT_N: usize = 512;
const HEAD_RADIUS: f32 = 0.0875; // m
const SPEED: f32 = 343.0;

fn main() {
    let out_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "assets/baked/chamber-default.chamber".to_string());

    let mut b = AssetBuilder::new(SR, HRIR_LEN);

    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FFT_N);
    let ifft = planner.plan_fft_inverse(FFT_N);

    // Spherical grid: azimuth every 10°, elevation every 15° from -45° to +90°.
    let mut n_dirs = 0usize;
    let mut el_deg: f32 = -45.0;
    while el_deg <= 90.0 + 1e-3 {
        let el = el_deg.to_radians();
        // near the poles, fewer azimuths
        let az_step: f32 = if el_deg.abs() >= 75.0 { 90.0 } else { 10.0 };
        let mut az_deg: f32 = -180.0;
        while az_deg < 180.0 - 1e-3 {
            let az = az_deg.to_radians();
            let (l, r, itd) = synth_hrir(az, el, &*fft, &*ifft);
            b.push_direction(az, el, itd, &l, &r);
            n_dirs += 1;
            az_deg += az_step;
        }
        el_deg += 15.0;
    }

    // Room presets (parametric FDN). dims (w,h,d) m; rt60 low/mid/high; absorption; order; wet.
    b.push_room(RoomPreset {
        name: "dry".into(),
        dims: [6.0, 3.0, 8.0],
        rt60: [0.18, 0.15, 0.12],
        wall_absorption: 0.9,
        reflection_order: 0,
        wet: 0.0,
        backend: ReverbBackend::Fdn,
    });
    b.push_room(RoomPreset {
        name: "room".into(),
        dims: [5.5, 3.0, 6.5],
        rt60: [0.55, 0.45, 0.30],
        wall_absorption: 0.22,
        reflection_order: 1,
        wet: 0.22,
        backend: ReverbBackend::Fdn,
    });
    b.push_room(RoomPreset {
        name: "hall".into(),
        dims: [18.0, 12.0, 28.0],
        rt60: [2.6, 2.1, 1.4],
        wall_absorption: 0.10,
        reflection_order: 1,
        wet: 0.32,
        backend: ReverbBackend::Fdn,
    });
    b.push_room(RoomPreset {
        name: "cathedral".into(),
        dims: [24.0, 22.0, 60.0],
        rt60: [5.5, 4.2, 2.4],
        wall_absorption: 0.06,
        reflection_order: 1,
        wet: 0.40,
        backend: ReverbBackend::Fdn,
    });

    let bytes = b.to_bytes();
    if let Some(dir) = std::path::Path::new(&out_path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::write(&out_path, &bytes).expect("write asset");
    println!(
        "baked {} directions, {} rooms -> {} ({:.1} KB)",
        n_dirs,
        4,
        out_path,
        bytes.len() as f32 / 1024.0
    );
}

/// Structural HRIR for one direction: returns (left[HRIR_LEN], right[HRIR_LEN], itd_samples).
fn synth_hrir(
    az: f32,
    el: f32,
    fft: &dyn rustfft::Fft<f32>,
    ifft: &dyn rustfft::Fft<f32>,
) -> (Vec<f32>, Vec<f32>, f32) {
    // Direction unit vector. Convention: +x right, +y up, +z back (front = -z),
    // azimuth measured toward +left.
    let ce = el.cos();
    let dir = [-ce * az.sin(), el.sin(), -ce * az.cos()];

    // Ear axes (unit): left = -x, right = +x.
    let cos_left = dot(dir, [-1.0, 0.0, 0.0]);
    let cos_right = dot(dir, [1.0, 0.0, 0.0]);

    let left = min_phase_ear(cos_left, el, fft, ifft);
    let right = min_phase_ear(cos_right, el, fft, ifft);

    // Woodworth spherical-head ITD. Lateral angle from the median plane.
    let lat = (ce * az.sin()).clamp(-1.0, 1.0).asin();
    let itd_sec = (HEAD_RADIUS / SPEED) * (lat + lat.sin());
    let itd_samples = itd_sec * SR; // >0 when source is toward +left => right ear delayed

    (left, right, itd_samples)
}

/// Build one ear's magnitude response, convert to a minimum-phase HRIR.
fn min_phase_ear(
    cos_incidence: f32,
    el: f32,
    fft: &dyn rustfft::Fft<f32>,
    ifft: &dyn rustfft::Fft<f32>,
) -> Vec<f32> {
    // full-spectrum magnitude (linear), length FFT_N (symmetric)
    let mut mag = vec![0.0f32; FFT_N];
    let half = FFT_N / 2;
    for k in 0..=half {
        let f = k as f32 * SR / FFT_N as f32;
        let m = ear_magnitude(f, cos_incidence, el);
        mag[k] = m;
        if k > 0 && k < half {
            mag[FFT_N - k] = m; // mirror
        }
    }

    // log magnitude (real), cepstrum via inverse FFT
    let mut buf: Vec<Complex<f32>> = mag
        .iter()
        .map(|&m| Complex::new(m.max(1e-7).ln(), 0.0))
        .collect();
    ifft.process(&mut buf);
    let scale = 1.0 / FFT_N as f32;
    for v in buf.iter_mut() {
        *v *= scale;
    }

    // minimum-phase cepstral window: keep causal part, double positive quefrencies
    let mut ceps = buf;
    for k in 0..FFT_N {
        let w = if k == 0 || k == half {
            1.0
        } else if k < half {
            2.0
        } else {
            0.0
        };
        ceps[k] = Complex::new(ceps[k].re * w, 0.0);
    }

    // forward FFT -> complex log spectrum; exponentiate to get min-phase spectrum
    fft.process(&mut ceps);
    for v in ceps.iter_mut() {
        let mag = v.re.exp();
        let ph = v.im;
        *v = Complex::new(mag * ph.cos(), mag * ph.sin());
    }

    // inverse FFT -> real minimum-phase impulse; take first HRIR_LEN taps
    ifft.process(&mut ceps);
    let mut h = vec![0.0f32; HRIR_LEN];
    for k in 0..HRIR_LEN {
        h[k] = ceps[k].re * scale;
    }
    h
}

/// Frequency-dependent ear magnitude (linear). Combines a smooth head-shadow ILD that
/// grows with frequency and lateralization, plus an elevation-dependent pinna notch.
fn ear_magnitude(f: f32, cos_incidence: f32, el: f32) -> f32 {
    // cos_incidence: +1 source directly at this ear, -1 opposite side.
    // Head shadow: far ear loses up to ~18 dB at high frequency.
    let shadow_amt = (1.0 - cos_incidence) * 0.5; // 0 near, 1 far
    let f_knee = 1200.0;
    let hf = f / (f + f_knee); // 0 at DC -> 1 at HF
    let shadow_db = -18.0 * shadow_amt * hf;

    // Slight near-ear HF emphasis (concha gain).
    let near_db = 3.0 * (0.5 + 0.5 * cos_incidence) * hf;

    // Pinna notch: a dip whose centre frequency rises with elevation (~6–11 kHz),
    // present mostly for frontal/upper directions. Drives elevation/front-back.
    let notch_f = 6000.0 + 4500.0 * (el.sin().clamp(-1.0, 1.0));
    let q = 4.0;
    let notch_depth_db = -11.0 * (0.5 + 0.5 * cos_incidence).clamp(0.0, 1.0);
    let x = (f - notch_f) / (notch_f / q);
    let notch_db = notch_depth_db * (-x * x).exp();

    // Gentle overall HF rolloff above ~15 kHz (anti-aliasing-ish).
    let roll_db = if f > 15000.0 {
        -6.0 * (f - 15000.0) / 5000.0
    } else {
        0.0
    };

    let total_db = shadow_db + near_db + notch_db + roll_db;
    10f32.powf(total_db / 20.0)
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

// silence unused import warning when PI not referenced after edits
#[allow(dead_code)]
const _PI: f32 = PI;
