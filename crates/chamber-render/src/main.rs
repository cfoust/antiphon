//! Offline scene -> stereo WAV renderer.
//!
//! This is the audible quality check (and the parity oracle for the wasm build). It
//! drives `chamber-dsp` deterministically, block by block, exactly as a real-time host
//! would, and writes 48 kHz/16-bit stereo WAVs you can listen to on headphones.
//!
//! Usage:
//!   chamber-render [asset.chamber] [out_dir]
//! Renders the full demo set into `out_dir` (default `out/`).

use chamber_assets::ChamberAsset;
use chamber_dsp::{Pose, Quat, Renderer, Source, Vec3};
use std::f32::consts::PI;

const SR: f32 = 48_000.0;
const BLOCK: usize = 128;

fn main() {
    // Deterministic parity scene shared with the wasm host (tools/parity.mjs).
    if std::env::args().nth(1).as_deref() == Some("parity") {
        let asset_path = std::env::args()
            .nth(2)
            .unwrap_or_else(|| "assets/baked/chamber-default.chamber".to_string());
        run_parity(&asset_path);
        return;
    }

    let asset_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "assets/baked/chamber-default.chamber".to_string());
    let out_dir = std::env::args().nth(2).unwrap_or_else(|| "out".to_string());
    std::fs::create_dir_all(&out_dir).expect("mkdir out");

    let bytes = std::fs::read(&asset_path).expect("read asset");
    let asset = ChamberAsset::parse(&bytes).expect("parse asset");
    println!(
        "loaded {}: {} dirs, {} rooms, hrir_len {}",
        asset_path,
        asset.directions.len(),
        asset.rooms.len(),
        asset.hrir_len
    );
    let room_names: Vec<String> = asset.rooms.iter().map(|r| r.name.clone()).collect();

    // --- Scene 1: a voice orbiting the head once (azimuth localization) ---
    render(&asset, &out_dir, "01_orbit_dry", room_of(&room_names, "dry"), 8.0, |t, srcs, pose| {
        let ang = 2.0 * PI * (t / 8.0); // full circle
        let r = 1.6;
        srcs[0].position = Vec3::new(r * ang.sin(), 0.0, -r * ang.cos());
        *pose = Pose::default();
    }, &[voice(220.0)]);

    // --- Scene 2: same orbit, but in a reverberant room (externalization) ---
    render(&asset, &out_dir, "02_orbit_room", room_of(&room_names, "room"), 8.0, |t, srcs, pose| {
        let ang = 2.0 * PI * (t / 8.0);
        let r = 1.6;
        srcs[0].position = Vec3::new(r * ang.sin(), 0.0, -r * ang.cos());
        *pose = Pose::default();
    }, &[voice(220.0)]);

    // --- Scene 3: orbit in a big hall ---
    render(&asset, &out_dir, "03_orbit_hall", room_of(&room_names, "hall"), 10.0, |t, srcs, pose| {
        let ang = 2.0 * PI * (t / 10.0);
        let r = 1.8;
        srcs[0].position = Vec3::new(r * ang.sin(), 0.0, -r * ang.cos());
        *pose = Pose::default();
    }, &[voice(196.0)]);

    // --- Scene 4: source fixed in front, listener turns head +-90 deg ---
    render(&asset, &out_dir, "04_headturn", room_of(&room_names, "room"), 8.0, |t, srcs, pose| {
        srcs[0].position = Vec3::new(0.0, 0.0, -1.6); // straight ahead
        let yaw = (2.0 * PI * (t / 4.0)).sin() * (PI / 2.0); // sweep +-90
        *pose = Pose::from_yaw(yaw);
    }, &[noise_bursts()]);

    // --- Scene 5: elevation sweep (pinna / up-down cue) ---
    render(&asset, &out_dir, "05_elevation", room_of(&room_names, "dry"), 8.0, |t, srcs, pose| {
        let el = (2.0 * PI * (t / 8.0)).sin() * (PI / 3.0); // +-60 deg
        let r = 1.6;
        srcs[0].position = Vec3::new(0.0, r * el.sin(), -r * el.cos());
        *pose = Pose::default();
    }, &[noise_bursts()]);

    // --- Scene 6: distance fly-by, far -> near -> far, passing the right ear ---
    render(&asset, &out_dir, "06_distance", room_of(&room_names, "room"), 8.0, |t, srcs, pose| {
        let x = 6.0 * (t / 8.0) - 3.0; // -3 .. +3 m, moving left->right
        srcs[0].position = Vec3::new(x, 0.0, -0.5);
        *pose = Pose::default();
    }, &[voice(165.0)]);

    // --- Scene 7: five voices on a frontal arc (the "chamber" layout) ---
    {
        let sigs: Vec<Vec<f32>> = (0..5)
            .map(|i| voice(150.0 + 35.0 * i as f32))
            .collect();
        let sig_refs: Vec<&[f32]> = sigs.iter().map(|v| v.as_slice()).collect();
        render_multi(&asset, &out_dir, "07_arc_five", room_of(&room_names, "hall"), 9.0, |_t, srcs, pose| {
            let n = srcs.len();
            for (i, s) in srcs.iter_mut().enumerate() {
                let bearing = -PI / 2.0 + PI * (i as f32) / (n as f32 - 1.0);
                let r = 2.2;
                s.position = Vec3::new(r * bearing.sin(), 0.0, -r * bearing.cos());
            }
            *pose = Pose::default();
        }, &sig_refs);
    }

    println!("done. wrote demos to {}/", out_dir);
}

/// Canonical, fully-deterministic scene used to verify native vs wasm parity.
/// A single fixed source, room preset 0 (dry), identity pose, LCG white-noise input.
/// Writes `out/parity_native.wav` and the raw input `out/parity_input.bin` (f32le)
/// so the wasm host renders byte-identical input.
fn run_parity(asset_path: &str) {
    std::fs::create_dir_all("out").unwrap();
    let bytes = std::fs::read(asset_path).expect("read asset");
    let asset = ChamberAsset::parse(&bytes).expect("parse asset");
    let mut r = Renderer::new(&asset, SR, 1, BLOCK);
    r.set_room(0);
    r.set_master_gain(0.9);

    let total = (0.5 * SR) as usize;
    let mut rng = Lcg(0xC0FFEE11);
    let input: Vec<f32> = (0..total).map(|_| 0.25 * rng.next_f()).collect();
    std::fs::write(
        "out/parity_input.bin",
        input.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>(),
    )
    .unwrap();

    let src = vec![Source::new(Vec3::new(0.9, 0.0, -1.3), 0.9)]; // ~35° right
    let pose = Pose::default();
    let mut out_l = vec![0.0; BLOCK];
    let mut out_r = vec![0.0; BLOCK];
    let mut stereo = Vec::with_capacity(total * 2);
    let mut pos = 0;
    while pos < total {
        let n = BLOCK.min(total - pos);
        let inref: Vec<&[f32]> = vec![&input[pos..pos + n]];
        r.process(&pose, &src, &inref, &mut out_l, &mut out_r, n);
        for i in 0..n {
            stereo.push(out_l[i]);
            stereo.push(out_r[i]);
        }
        pos += n;
    }
    write_wav("out/parity_native.wav", &stereo);
    // also dump raw f32 stereo for exact comparison
    std::fs::write(
        "out/parity_native.f32",
        stereo.iter().flat_map(|x| x.to_le_bytes()).collect::<Vec<u8>>(),
    )
    .unwrap();
    println!("parity: wrote out/parity_native.wav ({} frames)", total);
}

fn room_of(names: &[String], want: &str) -> usize {
    names.iter().position(|n| n == want).unwrap_or(0)
}

/// Render a single-source scene.
fn render<F: FnMut(f32, &mut [Source], &mut Pose)>(
    asset: &ChamberAsset,
    out_dir: &str,
    name: &str,
    room: usize,
    dur: f32,
    update: F,
    signal: &[Vec<f32>],
) {
    let refs: Vec<&[f32]> = signal.iter().map(|v| v.as_slice()).collect();
    render_multi(asset, out_dir, name, room, dur, update, &refs);
}

/// Render an N-source scene. `update(t, sources, pose)` is called once per block.
fn render_multi<F: FnMut(f32, &mut [Source], &mut Pose)>(
    asset: &ChamberAsset,
    out_dir: &str,
    name: &str,
    room: usize,
    dur: f32,
    mut update: F,
    signals: &[&[f32]],
) {
    let nsrc = signals.len();
    let mut r = Renderer::new(asset, SR, nsrc.max(1), BLOCK);
    r.set_room(room);
    r.set_master_gain(0.9);

    let total = (dur * SR) as usize;
    let mut sources: Vec<Source> = (0..nsrc)
        .map(|_| Source::new(Vec3::new(0.0, 0.0, -1.5), 0.9))
        .collect();
    let mut pose = Pose::default();

    let mut out_l = vec![0.0f32; BLOCK];
    let mut out_r = vec![0.0f32; BLOCK];
    let mut stereo: Vec<f32> = Vec::with_capacity(total * 2);

    let mut pos = 0usize;
    while pos < total {
        let n = BLOCK.min(total - pos);
        let t = pos as f32 / SR;
        update(t, &mut sources, &mut pose);

        // assemble per-source input slices for this block (looping the signal)
        let mut inbufs: Vec<Vec<f32>> = Vec::with_capacity(nsrc);
        for s in signals {
            let mut buf = vec![0.0f32; n];
            for (i, b) in buf.iter_mut().enumerate() {
                let idx = (pos + i) % s.len();
                *b = s[idx];
            }
            inbufs.push(buf);
        }
        let inrefs: Vec<&[f32]> = inbufs.iter().map(|v| v.as_slice()).collect();

        r.process(&pose, &sources, &inrefs, &mut out_l, &mut out_r, n);

        for i in 0..n {
            stereo.push(out_l[i]);
            stereo.push(out_r[i]);
        }
        pos += n;
    }

    let path = format!("{}/{}.wav", out_dir, name);
    write_wav(&path, &stereo);
    let peak = stereo.iter().fold(0.0f32, |a, &x| a.max(x.abs()));
    println!("  {:<16} room={} {:.1}s  peak={:.3}", name, room, dur, peak);
    let _ = Quat::IDENTITY; // keep import used
}

fn write_wav(path: &str, interleaved: &[f32]) {
    let spec = hound::WavSpec {
        channels: 2,
        sample_rate: SR as u32,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut w = hound::WavWriter::create(path, spec).expect("create wav");
    for &x in interleaved {
        let v = (x.clamp(-1.0, 1.0) * 32767.0) as i16;
        w.write_sample(v).unwrap();
    }
    w.finalize().unwrap();
}

// ---------------------------------------------------------------------------
// Deterministic test signals (no rand dependency)
// ---------------------------------------------------------------------------

struct Lcg(u32);
impl Lcg {
    fn next_f(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        (self.0 >> 8) as f32 / (1u32 << 24) as f32 * 2.0 - 1.0
    }
}

/// A voice-like mono signal: a few harmonics with vibrato, gated into syllables.
fn voice(f0: f32) -> Vec<f32> {
    let dur = 3.0;
    let n = (dur * SR) as usize;
    let mut out = vec![0.0f32; n];
    // simple two-formant emphasis via fixed harmonic weights
    let harmonics = [
        (1.0, 1.0),
        (2.0, 0.6),
        (3.0, 0.7),
        (4.0, 0.5),
        (5.0, 0.35),
        (7.0, 0.4),
        (9.0, 0.25),
        (11.0, 0.18),
    ];
    for i in 0..n {
        let t = i as f32 / SR;
        let vib = 1.0 + 0.01 * (2.0 * PI * 5.0 * t).sin();
        let mut s = 0.0;
        for &(h, a) in &harmonics {
            s += a * (2.0 * PI * f0 * h * vib * t).sin();
        }
        // syllable envelope: ~3 Hz amplitude gate with attack/decay
        let g = (0.5 - 0.5 * (2.0 * PI * 2.6 * t).cos()).powf(1.5);
        out[i] = 0.16 * s * g;
    }
    out
}

/// Pink-ish noise gated into short bursts — excellent for judging localization.
fn noise_bursts() -> Vec<f32> {
    let dur = 3.0;
    let n = (dur * SR) as usize;
    let mut out = vec![0.0f32; n];
    let mut rng = Lcg(0x1234_5678);
    // one-pole lowpass to tilt white -> pink-ish
    let mut lp = 0.0f32;
    for i in 0..n {
        let t = i as f32 / SR;
        let white = rng.next_f();
        lp += 0.15 * (white - lp);
        let burst_phase = (t * 2.5) % 1.0;
        let gate = if burst_phase < 0.35 {
            // raised-cosine window over the burst
            let x = burst_phase / 0.35;
            (0.5 - 0.5 * (2.0 * PI * x).cos()).sqrt()
        } else {
            0.0
        };
        out[i] = 0.5 * (0.6 * lp + 0.4 * white) * gate;
    }
    out
}
