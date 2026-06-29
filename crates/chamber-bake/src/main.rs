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
    // Args: [out.chamber] [--sofa <file>]
    let args: Vec<String> = std::env::args().collect();
    let sofa_path = args
        .iter()
        .position(|a| a == "--sofa")
        .and_then(|i| args.get(i + 1))
        .cloned();
    let out_path = args
        .iter()
        .skip(1)
        .find(|a| !a.starts_with("--") && Some(*a) != sofa_path.as_ref())
        .cloned()
        .unwrap_or_else(|| "assets/baked/chamber-default.chamber".to_string());

    let mut b = AssetBuilder::new(SR, HRIR_LEN);

    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(FFT_N);
    let ifft = planner.plan_fft_inverse(FFT_N);

    let n_dirs = if let Some(sp) = sofa_path {
        bake_hrtf_from_sofa(&sp, &mut b, &*fft, &*ifft)
    } else {
        bake_hrtf_analytic(&mut b, &*fft, &*ifft)
    };

    // Room presets. dims (w,h,d) m; rt60 low/mid/high; absorption; reflection order; wet.
    // FDN (parametric) rooms first, then matching convolution (BRIR) rooms so you can A/B
    // the two backends by ear. Convolution rooms get a stereo late-BRIR — synthesized here
    // (early reflections + decorrelated, frequency-damped diffuse tail), or loaded from
    // assets/brir/<name>.wav if a measured 48 kHz stereo file is present.
    let mut mk = |name: &str, dims: [f32; 3], rt60: [f32; 3], abs: f32, order: u32, wet: f32,
                  backend: ReverbBackend| {
        let (ir_left, ir_right) = if backend == ReverbBackend::Convolution {
            match load_brir_wav(name) {
                Some(ir) => {
                    println!("  room '{}': using measured BRIR assets/brir/{}.wav", name, name);
                    ir
                }
                None => synth_brir(rt60[1], rt60[2], dims, 1.2),
            }
        } else {
            (Vec::new(), Vec::new())
        };
        b.push_room(RoomPreset {
            name: name.into(),
            dims,
            rt60,
            wall_absorption: abs,
            reflection_order: order,
            wet,
            backend,
            ir_left,
            ir_right,
        });
    };
    use ReverbBackend::{Convolution, Fdn};
    mk("dry", [6.0, 3.0, 8.0], [0.18, 0.15, 0.12], 0.9, 0, 0.0, Fdn);
    mk("room", [5.5, 3.0, 6.5], [0.55, 0.45, 0.30], 0.22, 2, 0.22, Fdn);
    mk("hall", [18.0, 12.0, 28.0], [2.6, 2.1, 1.4], 0.10, 2, 0.32, Fdn);
    mk("cathedral", [24.0, 22.0, 60.0], [5.5, 4.2, 2.4], 0.06, 1, 0.40, Fdn);
    mk("room_conv", [5.5, 3.0, 6.5], [0.55, 0.45, 0.30], 0.22, 2, 0.9, Convolution);
    mk("hall_conv", [18.0, 12.0, 28.0], [2.6, 2.1, 1.4], 0.10, 2, 0.9, Convolution);

    let bytes = b.to_bytes();
    if let Some(dir) = std::path::Path::new(&out_path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::write(&out_path, &bytes).expect("write asset");
    println!(
        "baked {} directions, {} rooms -> {} ({:.1} KB)",
        n_dirs,
        b.rooms.len(),
        out_path,
        bytes.len() as f32 / 1024.0
    );
}

/// Deterministic LCG for synthesizing diffuse reverb noise.
struct Lcg(u32);
impl Lcg {
    fn nf(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.0 >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0
    }
}

/// Synthesize a stereo late-BRIR: a few early reflections followed by a decorrelated,
/// frequency-damped exponentially-decaying diffuse tail. A stand-in until a measured BRIR
/// is dropped in — same runtime path, just better data.
fn synth_brir(rt60_mid: f32, rt60_high: f32, dims: [f32; 3], max_len_s: f32) -> (Vec<f32>, Vec<f32>) {
    let len = ((rt60_mid * 1.05).min(max_len_s) * SR) as usize;
    let mut l = vec![0.0f32; len];
    let mut r = vec![0.0f32; len];
    let mut rng = Lcg(0x9E3779B1);

    // Early reflections: sparse taps in the first ~60 ms, spacing scaled by room size.
    let size = (dims[0] + dims[1] + dims[2]) / 3.0;
    let early_n = 14;
    for k in 0..early_n {
        let t = 0.004 + 0.0035 * k as f32 * (size / 10.0).clamp(0.4, 2.5);
        let i = (t * SR) as usize;
        if i >= len {
            break;
        }
        let amp = 0.5 * 0.82f32.powi(k as i32);
        // slightly different arrival per ear -> width
        let il = i;
        let ir = (i as f32 + 2.0 + 6.0 * rng.nf().abs()) as usize;
        l[il] += amp * sign(rng.nf());
        if ir < len {
            r[ir] += amp * sign(rng.nf());
        }
    }

    // Diffuse tail: independent noise per ear (decorrelation), shared decay envelope, with
    // a one-pole lowpass whose damping increases over time (HF decays faster).
    let mut lp_l = 0.0f32;
    let mut lp_r = 0.0f32;
    let hf_ratio = (rt60_high / rt60_mid).clamp(0.2, 1.0);
    for i in 0..len {
        let t = i as f32 / SR;
        let env = (-6.9077 * t / rt60_mid).exp(); // -60 dB at rt60_mid
        // damping coefficient: more HF loss later in the tail
        let a = (0.9 - 0.5 * (1.0 - hf_ratio) * (t / rt60_mid).min(1.0)).clamp(0.05, 0.95);
        let nl = rng.nf();
        let nr = rng.nf();
        lp_l += a * (nl - lp_l);
        lp_r += a * (nr - lp_r);
        l[i] += 0.6 * env * lp_l;
        r[i] += 0.6 * env * lp_r;
    }

    // normalize peak to ~0.5 (runtime `wet` then sets level)
    let peak = l
        .iter()
        .chain(r.iter())
        .fold(0.0f32, |m, &x| m.max(x.abs()))
        .max(1e-6);
    let g = 0.5 / peak;
    for x in l.iter_mut().chain(r.iter_mut()) {
        *x *= g;
    }
    (l, r)
}

/// Load a measured stereo BRIR from `assets/brir/<name>.wav` (expects 48 kHz, 2 channels).
fn load_brir_wav(name: &str) -> Option<(Vec<f32>, Vec<f32>)> {
    let path = format!("assets/brir/{}.wav", name);
    let mut reader = hound::WavReader::open(&path).ok()?;
    let spec = reader.spec();
    if spec.channels != 2 {
        eprintln!("  brir {}: expected 2 channels, got {}", path, spec.channels);
        return None;
    }
    if spec.sample_rate != SR as u32 {
        eprintln!(
            "  brir {}: expected {} Hz, got {} (resample offline first)",
            path, SR, spec.sample_rate
        );
        return None;
    }
    let mut l = Vec::new();
    let mut r = Vec::new();
    match spec.sample_format {
        hound::SampleFormat::Float => {
            for (i, s) in reader.samples::<f32>().flatten().enumerate() {
                if i % 2 == 0 {
                    l.push(s)
                } else {
                    r.push(s)
                }
            }
        }
        hound::SampleFormat::Int => {
            let scale = 1.0 / (1i64 << (spec.bits_per_sample - 1)) as f32;
            for (i, s) in reader.samples::<i32>().flatten().enumerate() {
                let v = s as f32 * scale;
                if i % 2 == 0 {
                    l.push(v)
                } else {
                    r.push(v)
                }
            }
        }
    }
    Some((l, r))
}

fn sign(x: f32) -> f32 {
    if x >= 0.0 {
        1.0
    } else {
        -1.0
    }
}

/// Analytic structural HRTF over a spherical grid. Returns the number of directions.
fn bake_hrtf_analytic(
    b: &mut AssetBuilder,
    fft: &dyn rustfft::Fft<f32>,
    ifft: &dyn rustfft::Fft<f32>,
) -> usize {
    let mut n = 0usize;
    let mut el_deg: f32 = -45.0;
    while el_deg <= 90.0 + 1e-3 {
        let el = el_deg.to_radians();
        let az_step: f32 = if el_deg.abs() >= 75.0 { 90.0 } else { 10.0 };
        let mut az_deg: f32 = -180.0;
        while az_deg < 180.0 - 1e-3 {
            let az = az_deg.to_radians();
            let (l, r, itd) = synth_hrir(az, el, fft, ifft);
            b.push_direction(az, el, itd, &l, &r);
            n += 1;
            az_deg += az_step;
        }
        el_deg += 15.0;
    }
    n
}

/// Import a measured SOFA HRTF, sampling it onto our spherical grid (each grid point filled
/// by libmysofa's nearest-measurement lookup, resampled to 48 kHz on open). Each ear's
/// measured magnitude is converted to minimum phase; the interaural delay is extracted from
/// the raw IR onsets (plus any stored delay) and carried separately as the ITD.
#[cfg(feature = "sofa")]
fn bake_hrtf_from_sofa(
    path: &str,
    b: &mut AssetBuilder,
    fft: &dyn rustfft::Fft<f32>,
    ifft: &dyn rustfft::Fft<f32>,
) -> usize {
    use sofar::reader::{Filter, OpenOptions};

    let sofa = OpenOptions::new()
        .sample_rate(SR)
        .open(path)
        .unwrap_or_else(|e| panic!("open SOFA {}: {:?}", path, e));
    let flen = sofa.filter_len();
    println!("  SOFA {}: filter_len {} @ {} Hz", path, flen, SR);
    let mut filt = Filter::new(flen);

    let mut n = 0usize;
    let mut el_deg: f32 = -45.0;
    while el_deg <= 90.0 + 1e-3 {
        let el = el_deg.to_radians();
        let az_step: f32 = if el_deg.abs() >= 75.0 { 90.0 } else { 10.0 };
        let mut az_deg: f32 = -180.0;
        while az_deg < 180.0 - 1e-3 {
            let az = az_deg.to_radians();
            // SOFA cartesian: +x front, +y left, +z up; az measured CCW toward +left.
            let (ce, se) = (el.cos(), el.sin());
            let (x, y, z) = (ce * az.cos(), ce * az.sin(), se);
            sofa.filter(x, y, z, &mut filt);

            let mag_l = mag_of_ir(&filt.left, fft);
            let mag_r = mag_of_ir(&filt.right, fft);
            let hl = min_phase_from_mag(&mag_l, fft, ifft);
            let hr = min_phase_from_mag(&mag_r, fft, ifft);

            // ITD: onset difference (samples) plus any stored per-ear delay.
            let onset_l = onset_samples(&filt.left) + filt.ldelay * SR;
            let onset_r = onset_samples(&filt.right) + filt.rdelay * SR;
            let itd = (onset_r - onset_l).clamp(-60.0, 60.0);

            b.push_direction(az, el, itd, &hl, &hr);
            n += 1;
            az_deg += az_step;
        }
        el_deg += 15.0;
    }
    n
}

#[cfg(not(feature = "sofa"))]
fn bake_hrtf_from_sofa(
    _path: &str,
    _b: &mut AssetBuilder,
    _fft: &dyn rustfft::Fft<f32>,
    _ifft: &dyn rustfft::Fft<f32>,
) -> usize {
    eprintln!("error: --sofa requires building with `--features sofa` (pulls in libmysofa).");
    std::process::exit(1);
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

/// Build one ear's magnitude response (analytic model), convert to a minimum-phase HRIR.
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
    min_phase_from_mag(&mag, fft, ifft)
}

/// Real-cepstrum minimum-phase reconstruction from a full-spectrum magnitude (length
/// FFT_N, symmetric). Shared by the analytic model and the SOFA importer. Returns HRIR_LEN
/// taps with energy front-loaded at t=0 (the bulk delay removed — carried as ITD instead).
fn min_phase_from_mag(
    mag: &[f32],
    fft: &dyn rustfft::Fft<f32>,
    ifft: &dyn rustfft::Fft<f32>,
) -> Vec<f32> {
    let half = FFT_N / 2;
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
    fft.process(&mut ceps);
    for v in ceps.iter_mut() {
        let mag = v.re.exp();
        let ph = v.im;
        *v = Complex::new(mag * ph.cos(), mag * ph.sin());
    }
    ifft.process(&mut ceps);
    let mut h = vec![0.0f32; HRIR_LEN];
    for k in 0..HRIR_LEN {
        h[k] = ceps[k].re * scale;
    }
    h
}

/// Magnitude spectrum (length FFT_N, symmetric) of a time-domain IR, zero-padded/truncated.
#[cfg(feature = "sofa")]
fn mag_of_ir(ir: &[f32], fft: &dyn rustfft::Fft<f32>) -> Vec<f32> {
    let mut buf = vec![Complex::new(0.0f32, 0.0); FFT_N];
    for (i, &x) in ir.iter().take(FFT_N).enumerate() {
        buf[i] = Complex::new(x, 0.0);
    }
    fft.process(&mut buf);
    buf.iter().map(|c| c.norm()).collect()
}

/// Fractional onset (samples) of an IR: first crossing of −15 dB of peak, linearly
/// interpolated. Used to estimate the per-ear arrival time for the ITD.
#[cfg(feature = "sofa")]
fn onset_samples(ir: &[f32]) -> f32 {
    let peak = ir.iter().fold(0.0f32, |m, &x| m.max(x.abs())).max(1e-9);
    let thresh = peak * 0.178; // -15 dB
    for i in 1..ir.len() {
        if ir[i].abs() >= thresh {
            let a = ir[i - 1].abs();
            let b = ir[i].abs();
            let frac = if b > a { (thresh - a) / (b - a) } else { 0.0 };
            return (i - 1) as f32 + frac.clamp(0.0, 1.0);
        }
    }
    0.0
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
