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
    // `suite <wav_dir> <out_dir>`: A/B test matrix for the Chamber application.
    if std::env::args().nth(1).as_deref() == Some("suite") {
        let a: Vec<String> = std::env::args().collect();
        run_suite(
            a.get(2).map(|s| s.as_str()).unwrap_or("out/voices_src"),
            a.get(3).map(|s| s.as_str()).unwrap_or("out/suite"),
        );
        return;
    }
    // `voices <wav_dir> <asset> <out_dir>`: render real voice lines placed in space.
    if std::env::args().nth(1).as_deref() == Some("voices") {
        let a: Vec<String> = std::env::args().collect();
        run_voices(
            a.get(2).map(|s| s.as_str()).unwrap_or("out/voices_src"),
            a.get(3).map(|s| s.as_str()).unwrap_or("assets/baked/chamber-ari.chamber"),
            a.get(4).map(|s| s.as_str()).unwrap_or("out/voices"),
        );
        return;
    }
    if std::env::args().nth(1).as_deref() == Some("bench") {
        let asset = std::env::args()
            .nth(2)
            .unwrap_or_else(|| "assets/baked/chamber-default.chamber".to_string());
        run_bench(&asset);
        return;
    }
    // `shootout <asset> <out.wav> [voice.wav]`: the fixed ELO-shootout scene. A single voice tours
    // the hard cases (front arc, behind, angled+elevated) past a FIXED head, rendered through the
    // real Renderer so a candidate's DSP changes show up. Same scene/signal/asset for everyone.
    if std::env::args().nth(1).as_deref() == Some("shootout") {
        let a: Vec<String> = std::env::args().collect();
        let asset = a.get(2).cloned().unwrap_or_else(|| "assets/baked/chamber-default.chamber".into());
        let out = a.get(3).cloned().unwrap_or_else(|| "out/shootout/candidate.wav".into());
        let voice = a.get(4).cloned().unwrap_or_else(|| "tools/shootout/echo.wav".into());
        run_shootout(&asset, &out, &voice);
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

    // --- Scene 6: distance fly-by, far -> near -> far, grazing the right ear ---
    // Grazes ~0.12 m so the near-field DVF is unmistakable: as it passes on the right the right
    // ear should gain low end and the left ear lose it (ILD swelling at LOW freq, not just volume).
    render(&asset, &out_dir, "06_distance", room_of(&room_names, "room"), 8.0, |t, srcs, pose| {
        let x = 6.0 * (t / 8.0) - 3.0; // -3 .. +3 m, moving left->right
        srcs[0].position = Vec3::new(x, 0.0, -0.12);
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

    // --- Scene 8: orbit in the convolution (measured-BRIR-style) hall, A/B vs scene 3 ---
    render(&asset, &out_dir, "08_orbit_hall_conv", room_of(&room_names, "hall_conv"), 10.0, |t, srcs, pose| {
        let ang = 2.0 * PI * (t / 10.0);
        let r = 1.8;
        srcs[0].position = Vec3::new(r * ang.sin(), 0.0, -r * ang.cos());
        *pose = Pose::default();
    }, &[voice(196.0)]);

    // --- Scene 9: 6DoF — listener WALKS past three fixed voices (position, not just yaw) ---
    {
        let sigs = vec![voice(160.0), voice(210.0), voice(280.0)];
        let refs: Vec<&[f32]> = sigs.iter().map(|v| v.as_slice()).collect();
        render_multi(&asset, &out_dir, "09_walk_6dof", room_of(&room_names, "room"), 10.0, |t, srcs, pose| {
            // three voices fixed in the world, along a corridor
            srcs[0].position = Vec3::new(-1.2, 0.0, -2.0);
            srcs[1].position = Vec3::new(1.2, 0.0, -4.0);
            srcs[2].position = Vec3::new(-1.0, 0.0, -6.0);
            // listener walks forward (−z) from z=0 to z=−6, drifting side to side
            let z = -6.0 * (t / 10.0);
            let x = 0.5 * (2.0 * PI * t / 5.0).sin();
            pose.position = Vec3::new(x, 0.0, z);
            pose.orientation = Quat::from_yaw(0.0);
        }, &refs);
    }

    // --- Scene 10: same walk, but the measured-BRIR room (B0) — the diffuse tail is the BRIR,
    // the EARLY reflections are the translating ISM, so the room now moves with the listener. ---
    {
        let sigs = vec![voice(160.0), voice(210.0), voice(280.0)];
        let refs: Vec<&[f32]> = sigs.iter().map(|v| v.as_slice()).collect();
        render_multi(&asset, &out_dir, "10_walk_room_brir", room_of(&room_names, "room_conv"), 10.0, |t, srcs, pose| {
            srcs[0].position = Vec3::new(-1.2, 0.0, -2.0);
            srcs[1].position = Vec3::new(1.2, 0.0, -4.0);
            srcs[2].position = Vec3::new(-1.0, 0.0, -6.0);
            let z = -6.0 * (t / 10.0);
            let x = 0.5 * (2.0 * PI * t / 5.0).sin();
            pose.position = Vec3::new(x, 0.0, z);
            pose.orientation = Quat::from_yaw(0.0);
        }, &refs);
    }

    println!("done. wrote demos to {}/", out_dir);
}

const PING_FREQS: [f32; 6] = [523.25, 392.0, 587.33, 659.25, 783.99, 880.0];

fn angdiff(a: f32, b: f32) -> f32 {
    let mut d = (a - b) % (2.0 * PI);
    if d > PI { d -= 2.0 * PI }
    if d < -PI { d += 2.0 * PI }
    d
}

/// Current earcon: a near-pure decaying sine (+ one harmonic). Few spectral cues → tends
/// to localize poorly / collapse in-head.
fn ping_sine(freq: f32) -> Vec<f32> {
    let n = (0.6 * SR) as usize;
    (0..n)
        .map(|i| {
            let t = i as f32 / SR;
            let env = (-t * 7.0).exp();
            (((2.0 * PI * freq * t).sin()) * 0.5 + (2.0 * PI * freq * 1.5 * t).sin() * 0.22) * env
        })
        .collect()
}

/// Broadband earcon: a short filtered noise transient (rich pinna cues) + an inharmonic
/// tonal body. Externalizes far better through an HRTF.
fn ping_rich(freq: f32, seed: u32) -> Vec<f32> {
    let n = (0.6 * SR) as usize;
    let mut rng = Lcg(seed);
    let mut lp = 0.0f32;
    (0..n)
        .map(|i| {
            let t = i as f32 / SR;
            let env = (-t * 8.0).exp();
            // 10 ms noise transient, gently tilted (keeps energy in the pinna 3–9 kHz band)
            let click = if t < 0.012 {
                let w = rng.next_f();
                lp += 0.45 * (w - lp);
                (0.6 * lp + 0.4 * w) * (1.0 - t / 0.012)
            } else {
                0.0
            };
            let tone = (2.0 * PI * freq * t).sin() * 0.4
                + (2.0 * PI * freq * 2.01 * t).sin() * 0.16
                + (2.0 * PI * freq * 3.0 * t).sin() * 0.1;
            (0.55 * click + 0.45 * tone * env) * env.max(0.0)
        })
        .collect()
}

/// A/B suite for the Chamber application: full chamber scenes (HRTF × room) and isolated
/// earcon-externalization tests (sine vs broadband, side vs front, dry vs reverberant).
fn run_suite(wav_dir: &str, out_dir: &str) {
    std::fs::create_dir_all(out_dir).unwrap();
    let names = ["atlas", "echo", "wren", "cass", "iris", "rook"];
    let voices: Vec<Vec<f32>> = names
        .iter()
        .map(|n| load_wav_mono(&format!("{}/{}.wav", wav_dir, n)))
        .collect();

    let load = |p: &str| -> Option<ChamberAsset> {
        std::fs::read(p).ok().and_then(|b| ChamberAsset::parse(&b).ok())
    };
    let ari = load("assets/baked/chamber-ari.chamber");
    let kemar = load("assets/baked/chamber-kemar.chamber");
    let default = load("assets/baked/chamber-default.chamber");
    fn pick<'a>(a: &'a Option<ChamberAsset>, d: &'a Option<ChamberAsset>) -> Option<&'a ChamberAsset> {
        a.as_ref().or(d.as_ref())
    }

    println!("Chamber A/B suite -> {}/", out_dir);
    println!("  assets: ari={} kemar={} default={}", ari.is_some(), kemar.is_some(), default.is_some());

    // ---- full chamber scenes: 6 voices on a front arc, head pans, two agents emit pings ----
    if let Some(a) = pick(&ari, &default) {
        chamber_scene(a, out_dir, "scene_ari_hall", "hall", &voices, true);
        chamber_scene(a, out_dir, "scene_ari_room", "room", &voices, true);
        chamber_scene(a, out_dir, "scene_ari_hallconv", "hall_conv", &voices, true);
    }
    if let Some(a) = pick(&kemar, &default) {
        chamber_scene(a, out_dir, "scene_kemar_hall", "hall", &voices, true);
    }

    // ---- isolated earcon externalization tests (a ping every 1.5 s) ----
    let ping_asset = pick(&ari, &default).cloned();
    if let Some(a) = &ping_asset {
        // sine (current) vs broadband, at 60° right
        ping_test(a, out_dir, "ping_A_sine_dry", "dry", false, 60.0);
        ping_test(a, out_dir, "ping_B_sine_hall", "hall", false, 60.0);
        ping_test(a, out_dir, "ping_C_rich_hall", "hall", true, 60.0);
        ping_test(a, out_dir, "ping_D_rich_hallconv", "hall_conv", true, 60.0);
        // placement: front collapses more than the side
        ping_test(a, out_dir, "ping_E_rich_front", "hall", true, 0.0);
        ping_test(a, out_dir, "ping_F_rich_behind", "hall", true, 150.0);
    }

    // ---- reference: the single-voice orbit you liked ----
    if let Some(a) = pick(&ari, &default) {
        let r = room_idx(a, "hall");
        render_multi(a, out_dir, "ref_orbit_atlas", r, 16.0, |t, srcs, pose| {
            let ang = 2.0 * PI * (t / 12.0);
            srcs[0].position = Vec3::new(1.5 * ang.sin(), 0.0, -1.5 * ang.cos());
            srcs[0].gain = 0.95;
            *pose = Pose::default();
        }, &[voices[0].as_slice()]);
    }

    println!("done. listen in {}/ — read out/suite/README.txt", out_dir);
    let _ = std::fs::write(
        format!("{}/README.txt", out_dir),
        SUITE_README,
    );
}

fn room_idx(a: &ChamberAsset, want: &str) -> usize {
    a.rooms.iter().position(|r| r.name == want).unwrap_or(0)
}

/// Full chamber: 6 voices on a ±90° front arc, head pans ±70°, the faced voice opens up
/// (others a quiet bed), and two "done" agents emit pings from their own bearings.
fn chamber_scene(
    asset: &ChamberAsset,
    out_dir: &str,
    name: &str,
    room: &str,
    voices: &[Vec<f32>],
    rich_ping: bool,
) {
    let n = 6;
    let mut r = Renderer::new(asset, SR, n, BLOCK);
    r.set_room(room_idx(asset, room));
    r.set_master_gain(0.9);

    let pings: Vec<Vec<f32>> = (0..n)
        .map(|i| if rich_ping { ping_rich(PING_FREQS[i], 0x1000 + i as u32) } else { ping_sine(PING_FREQS[i]) })
        .collect();
    let done = [1usize, 4usize]; // these two emit pings
    let bearings: Vec<f32> = (0..n).map(|i| (-90.0 + 180.0 * i as f32 / 5.0).to_radians()).collect();

    let dur = 26.0;
    let total = (dur * SR) as usize;
    let mut out_l = vec![0.0; BLOCK];
    let mut out_r = vec![0.0; BLOCK];
    let mut stereo = Vec::with_capacity(total * 2);
    let mut srcs: Vec<Source> = (0..n).map(|_| Source::new(Vec3::new(0.0, 0.0, -2.4), 0.3)).collect();
    let mut inb: Vec<Vec<f32>> = (0..n).map(|_| vec![0.0; BLOCK]).collect();

    let mut pos = 0;
    while pos < total {
        let blk = BLOCK.min(total - pos);
        let t = pos as f32 / SR;
        let yaw = (2.0 * PI * t / 13.0).sin() * 70.0f32.to_radians(); // slow pan ±70°
        let pose = Pose::from_yaw(-yaw); // forward convention; matches the app

        for i in 0..n {
            let bearing = bearings[i];
            srcs[i].position = Vec3::new(2.4 * bearing.sin(), 0.0, -2.4 * bearing.cos());
            // focus: the agent nearest the head yaw opens up; others are a quiet bed
            let focus = angdiff(bearing, yaw).cos().max(0.0).powf(6.0);
            srcs[i].gain = 0.22 + 0.78 * focus;
            srcs[i].send = 0.3;
            for k in 0..blk {
                let v = voices[i][(pos + k) % voices[i].len()];
                let mut s = v;
                if done.contains(&i) {
                    let ph = ((t + 0.7 * i as f32) % 3.0) * SR; // ping every 3 s
                    let pi = ph as usize + k;
                    if pi < pings[i].len() {
                        s = v * 0.5 + pings[i][pi] * 0.7; // ping rides on top, same position
                    }
                }
                inb[i][k] = s;
            }
        }
        let refs: Vec<&[f32]> = inb.iter().map(|v| &v[..blk]).collect();
        r.process(&pose, &srcs, &refs, &mut out_l, &mut out_r, blk);
        for k in 0..blk {
            stereo.push(out_l[k]);
            stereo.push(out_r[k]);
        }
        pos += blk;
    }
    write_wav(&format!("{}/{}.wav", out_dir, name), &stereo);
    println!("  {:<22} room={} ping={}", name, room, if rich_ping { "rich" } else { "sine" });
}

/// Isolated earcon test: a single source at `bearing_deg`, emitting a ping every 1.5 s.
fn ping_test(asset: &ChamberAsset, out_dir: &str, name: &str, room: &str, rich: bool, bearing_deg: f32) {
    let mut r = Renderer::new(asset, SR, 1, BLOCK);
    r.set_room(room_idx(asset, room));
    r.set_master_gain(0.9);
    let ping = if rich { ping_rich(587.33, 0x55) } else { ping_sine(587.33) };
    let bearing = bearing_deg.to_radians();
    let src = [Source::new(Vec3::new(2.0 * bearing.sin(), 0.0, -2.0 * bearing.cos()), 0.9)];
    let pose = Pose::default();

    let dur = 10.0;
    let total = (dur * SR) as usize;
    let mut out_l = vec![0.0; BLOCK];
    let mut out_r = vec![0.0; BLOCK];
    let mut stereo = Vec::with_capacity(total * 2);
    let mut inb = vec![0.0f32; BLOCK];
    let mut pos = 0;
    while pos < total {
        let blk = BLOCK.min(total - pos);
        let t = pos as f32 / SR;
        for k in 0..blk {
            let ph = (((t) % 1.5) * SR) as usize + k;
            inb[k] = if ph < ping.len() { ping[ph] } else { 0.0 };
        }
        let refs: [&[f32]; 1] = [&inb[..blk]];
        r.process(&pose, &src, &refs, &mut out_l, &mut out_r, blk);
        for k in 0..blk {
            stereo.push(out_l[k]);
            stereo.push(out_r[k]);
        }
        pos += blk;
    }
    write_wav(&format!("{}/{}.wav", out_dir, name), &stereo);
    println!("  {:<22} room={} ping={} bearing={}°", name, room, if rich { "rich" } else { "sine" }, bearing_deg);
}

const SUITE_README: &str = "\
Chamber A/B suite — listen on headphones.

FULL SCENES (6 voices on a front arc, head slowly pans ±70°, agents 'echo' and 'iris'
emit pings from their own positions; the voice you face opens up, others stay a quiet bed):
  scene_ari_hall      ARI HRTF + hall reverb   (likely best — most externalized)
  scene_ari_room      ARI HRTF + smaller room  (drier, more intimate)
  scene_ari_hallconv  ARI HRTF + measured BRIR convolution room
  scene_kemar_hall    KEMAR (dummy head) + hall, to A/B the HRTF vs ARI

EARCON EXTERNALIZATION (the 'done' beep, one every 1.5 s, at 60° right unless noted):
  ping_A_sine_dry     pure sine, no reverb   — the in-head failure case (current app)
  ping_B_sine_hall    pure sine + hall       — reverb alone helps a little
  ping_C_rich_hall    broadband + hall       — should externalize clearly (recommended)
  ping_D_rich_hallconv broadband + BRIR room
  ping_E_rich_front   broadband, straight ahead — front collapses more than the side
  ping_F_rich_behind  broadband, 150° behind   — does it stay behind you?

REFERENCE:
  ref_orbit_atlas     single voice orbit, ARI+hall (the one that sounded best)

Tell me which scene (HRTF+room) and which earcon you prefer and I'll bake it into the app.
";

/// Load a mono WAV (any int/float, assumed already 48 kHz) into normalized f32.
fn load_wav_mono(path: &str) -> Vec<f32> {
    let mut r = hound::WavReader::open(path).unwrap_or_else(|e| panic!("open {}: {}", path, e));
    let spec = r.spec();
    let ch = spec.channels.max(1) as usize;
    let raw: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => r.samples::<f32>().flatten().collect(),
        hound::SampleFormat::Int => {
            let s = 1.0 / (1i64 << (spec.bits_per_sample - 1)) as f32;
            r.samples::<i32>().flatten().map(|v| v as f32 * s).collect()
        }
    };
    if ch == 1 {
        raw
    } else {
        raw.chunks(ch).map(|c| c.iter().sum::<f32>() / ch as f32).collect()
    }
}

/// Render the original-project voice lines placed in 3D space, three ways.
fn run_voices(wav_dir: &str, asset_path: &str, out_dir: &str) {
    std::fs::create_dir_all(out_dir).unwrap();
    let bytes = std::fs::read(asset_path).expect("asset");
    let asset = ChamberAsset::parse(&bytes).expect("parse asset");
    let names = ["atlas", "echo", "wren", "cass", "iris", "rook"];
    let sigs: Vec<Vec<f32>> = names
        .iter()
        .map(|n| load_wav_mono(&format!("{}/{}.wav", wav_dir, n)))
        .collect();
    let refs: Vec<&[f32]> = sigs.iter().map(|v| v.as_slice()).collect();
    let room = |want: &str| asset.rooms.iter().position(|r| r.name == want).unwrap_or(0);
    println!("voices from {} through {} ({} dirs)", wav_dir, asset_path, asset.directions.len());

    // 1) Six voices in a 360° ring around you; you slowly rotate to face each in turn.
    render_multi(&asset, out_dir, "ring6", room("room"), 22.0, |_t, srcs, pose| {
        let n = srcs.len();
        for (i, s) in srcs.iter_mut().enumerate() {
            let bearing = 2.0 * PI * i as f32 / n as f32; // 0,60,120,180,240,300°
            let r = 2.0;
            s.position = Vec3::new(r * bearing.sin(), 0.0, -r * bearing.cos());
            s.gain = 0.55;
        }
        // slow full head turn over the clip
        pose.orientation = Quat::from_yaw(2.0 * PI * (_t / 22.0));
        pose.position = Vec3::new(0.0, 0.0, 0.0);
    }, &refs);

    // 2) A single voice (atlas) orbiting your head in a hall.
    render_multi(&asset, out_dir, "orbit_atlas", room("hall"), 20.0, |t, srcs, pose| {
        let ang = 2.0 * PI * (t / 12.0);
        let r = 1.5;
        srcs[0].position = Vec3::new(r * ang.sin(), 0.3 * (0.5 * ang).sin(), -r * ang.cos());
        srcs[0].gain = 0.95;
        *pose = Pose::default();
    }, &refs[..1]);

    // 3) 6DoF — the six voices stand in a room and you walk through them.
    render_multi(&asset, out_dir, "walk_through", room("room"), 22.0, |t, srcs, pose| {
        let layout = [
            (-1.3, -2.0), (1.3, -3.2), (-1.1, -4.6),
            (1.2, -6.0), (-1.0, -7.4), (1.1, -8.8),
        ];
        for (i, s) in srcs.iter_mut().enumerate() {
            let (x, z) = layout[i];
            s.position = Vec3::new(x, 0.0, z);
            s.gain = 0.7;
        }
        let z = -9.5 * (t / 22.0); // walk forward past all six
        pose.position = Vec3::new(0.4 * (2.0 * PI * t / 6.0).sin(), 0.0, z);
        pose.orientation = Quat::from_yaw(0.3 * (2.0 * PI * t / 9.0).sin());
    }, &refs);

    println!("wrote {}/ring6.wav, orbit_atlas.wav, walk_through.wav", out_dir);
}

/// Render-time benchmark: how much faster than real time can we render N voices (with
/// order-2 reflections + reverb)? Reports the realtime multiple — the performance headroom.
fn run_bench(asset_path: &str) {
    let bytes = std::fs::read(asset_path).expect("asset");
    let asset = ChamberAsset::parse(&bytes).unwrap();
    println!("bench asset: {} ({} directions)", asset_path, asset.directions.len());
    for (room, n) in [("hall", 12usize), ("hall_conv", 12), ("dry", 12)] {
        let ridx = asset.rooms.iter().position(|r| r.name == room).unwrap_or(0);
        let mut r = Renderer::new(&asset, SR, n, BLOCK);
        r.set_room(ridx);
        let sigs: Vec<Vec<f32>> = (0..n).map(|i| voice(150.0 + 13.0 * i as f32)).collect();
        let srcs: Vec<Source> = (0..n)
            .map(|i| {
                let b = -PI / 2.0 + PI * i as f32 / (n as f32 - 1.0);
                Source::new(Vec3::new(2.0 * b.sin(), 0.0, -2.0 * b.cos()), 0.7)
            })
            .collect();
        let dur = 5.0;
        let total = (dur * SR) as usize;
        let mut ol = vec![0.0; BLOCK];
        let mut or = vec![0.0; BLOCK];
        let mut inb: Vec<Vec<f32>> = (0..n).map(|_| vec![0.0; BLOCK]).collect();
        let t0 = std::time::Instant::now();
        let mut pos = 0;
        while pos < total {
            for s in 0..n {
                for i in 0..BLOCK {
                    inb[s][i] = sigs[s][(pos + i) % sigs[s].len()];
                }
            }
            let refs: Vec<&[f32]> = inb.iter().map(|v| v.as_slice()).collect();
            r.process(&Pose::from_yaw(0.2), &srcs, &refs, &mut ol, &mut or, BLOCK);
            pos += BLOCK;
        }
        let el = t0.elapsed().as_secs_f64();
        println!(
            "bench {:>10}: {} voices, {:.1}s audio in {:.3}s  ->  {:.1}x realtime",
            room, n, dur, el, dur as f64 / el
        );
    }
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

    // Near-field source (~0.36 m, to the right) so the parity oracle exercises the per-ear
    // near-field DVF shelf — the recursive filter is the only new float state crossing to wasm.
    let src = vec![Source::new(Vec3::new(0.3, 0.0, -0.2), 0.9)];
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

/// The fixed ELO-shootout scene: one voice tours the perceptually hard positions past a FIXED
/// head (so externalization/front-back isn't rescued by dynamic cues). Deterministic.
fn run_shootout(asset_path: &str, out_path: &str, voice_path: &str) {
    let bytes = std::fs::read(asset_path).expect("read asset");
    let asset = ChamberAsset::parse(&bytes).expect("parse asset");
    let room_names: Vec<String> = asset.rooms.iter().map(|r| r.name.clone()).collect();
    let mut r = Renderer::new(&asset, SR, 1, BLOCK);
    r.set_room(room_of(&room_names, "room")); // a modestly reverberant room (externalization)
    r.set_master_gain(0.9);
    // seeding hook: FREQ_SCALE lets us produce a "fit-on" candidate without code changes.
    if let Ok(v) = std::env::var("FREQ_SCALE").map(|s| s.parse::<f32>()) {
        if let Ok(s) = v {
            r.set_freq_scale(s);
        }
    }

    let sig = load_wav_mono(voice_path);
    let dur = 12.0f32;
    let total = (dur * SR) as usize;
    let pos_at = |t: f32| -> Vec3 {
        // azimuth (0 = front, + = left), elevation; r = 1.5 m
        let (az, el) = if t < 6.0 {
            ((70.0f32).to_radians() * (2.0 * PI * t / 3.0).sin(), 0.0) // front arc, back & forth
        } else {
            let u = t - 6.0;
            (2.0 * PI * u / 6.0, (25.0f32).to_radians() * (2.0 * PI * u / 3.0).sin()) // orbit + elev
        };
        let rr = 1.5;
        Vec3::new(-rr * el.cos() * az.sin(), rr * el.sin(), -rr * el.cos() * az.cos())
    };

    let mut out_l = vec![0.0f32; BLOCK];
    let mut out_r = vec![0.0f32; BLOCK];
    let mut stereo = Vec::with_capacity(total * 2);
    let (mut cursor, mut pos) = (0usize, 0usize);
    while pos < total {
        let n = BLOCK.min(total - pos);
        let t = pos as f32 / SR;
        let src = [Source::new(pos_at(t), 1.0)];
        let pose = Pose::default(); // head fixed, facing front
        let mut inp = vec![0.0f32; n];
        for v in inp.iter_mut() {
            *v = sig[cursor];
            cursor = (cursor + 1) % sig.len();
        }
        let inref: Vec<&[f32]> = vec![&inp];
        r.process(&pose, &src, &inref, &mut out_l, &mut out_r, n);
        for i in 0..n {
            stereo.push(out_l[i]);
            stereo.push(out_r[i]);
        }
        pos += n;
    }
    if let Some(d) = std::path::Path::new(out_path).parent() {
        std::fs::create_dir_all(d).ok();
    }
    write_wav(out_path, &stereo);
    let peak = stereo.iter().fold(0.0f32, |m, &x| m.max(x.abs()));
    println!("shootout: wrote {} ({:.0}s, peak {:.3})", out_path, dur, peak);
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
