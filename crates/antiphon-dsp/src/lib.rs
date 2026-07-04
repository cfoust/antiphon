//! Antiphon binaural rendering core.
//!
//! Real-time, platform-agnostic (native + wasm32), no I/O, no threads, and no
//! allocation on the audio path (everything is allocated in [`Renderer::new`]).
//!
//! Pipeline per block: for each mono source, compute its listener-relative direction
//! from the 6DoF pose, render the **direct path** (min-phase HRIR FIR + ITD + distance)
//! and a budget of **image-source early reflections** through the same HRTF kernel, and
//! feed a mono send to a parametric **FDN late reverb**. Sum, limit, output stereo.

pub mod attention;
pub mod dvf;
pub mod hrtf;
pub mod math;
pub mod reverb;
pub mod voice;

pub use attention::{AttentionCfg, AttentionCue};
pub use math::{Quat, Vec3};

use antiphon_assets::{AntiphonAsset, ReverbBackend, RoomPreset};
use hrtf::HrtfDb;
use reverb::{ConvReverb, Fdn};
use voice::{Decorrelator, Voice};

pub const SPEED_OF_SOUND: f32 = 343.0;
/// Height of the listener's ears above the room floor, in metres. The world origin is the
/// listener's nominal ear position: the room is x/z-centred on it, but vertically the floor
/// sits at `y = -EAR_HEIGHT_M` and the ceiling at `y = dims[1] - EAR_HEIGHT_M` — so a 12 m
/// hall towers above you instead of centring you 6 m off the floor. Rooms shorter than
/// 2·EAR_HEIGHT_M put the ears above mid-height (room-centre offset goes negative); the
/// image math stays valid.
pub const EAR_HEIGHT_M: f32 = 1.6;
const MAX_ITD_SAMPLES: usize = 64; // ~1.3 ms @48k
/// Image sources rendered per source. The **K loudest** images (energy-ranked by a
/// listener-independent proxy, so the image→slot map stays stable as the listener moves — no
/// reshuffle clicks) are kept, drawn from the full order-≤2 enumeration rather than just the
/// six first-order walls. Each image keeps a stable voice slot across blocks.
const REFLECT_PER_SOURCE: usize = 8;
/// Reflections use a shorter HRIR than the direct path — they're spectrally less critical,
/// and this keeps the per-image cost low enough for real time (esp. WASM).
const REFL_TAPS: usize = 64;
/// Satellite taps rendered for a volumetric source (`extent > 0`), in addition to the centre
/// voice. Fixed world-space tetrahedral offsets scaled by the extent radius, each fed a
/// velvet-noise-decorrelated copy of the input, power-conserving gain split. A source with
/// `extent == 0` skips all of this — bit-exact with the point-source path.
const EXTENT_TAPS: usize = 4;
/// Extent radii are clamped here; sizes the satellite pre-delay lines.
const MAX_EXTENT: f32 = 8.0;
/// Unit tetrahedron vertices (scaled by `extent` for the satellite offsets).
const EXTENT_OFFSETS: [[f32; 3]; EXTENT_TAPS] = [
    [0.577_350_3, 0.577_350_3, 0.577_350_3],
    [0.577_350_3, -0.577_350_3, -0.577_350_3],
    [-0.577_350_3, 0.577_350_3, -0.577_350_3],
    [-0.577_350_3, -0.577_350_3, 0.577_350_3],
];

/// Listener head pose. Position in world metres; orientation maps body axes to world.
#[derive(Clone, Copy, Debug)]
pub struct Pose {
    pub position: Vec3,
    pub orientation: Quat,
}
impl Default for Pose {
    fn default() -> Self {
        Pose {
            position: Vec3::new(0.0, 0.0, 0.0),
            orientation: Quat::IDENTITY,
        }
    }
}
impl Pose {
    pub fn from_yaw(yaw: f32) -> Pose {
        Pose {
            position: Vec3::new(0.0, 0.0, 0.0),
            orientation: Quat::from_yaw(yaw),
        }
    }
}

/// A mono source placed in world space. Defaults to an omnidirectional point source;
/// `facing`/`directivity` give it a frequency-dependent radiation pattern and `extent` a
/// physical size. Both default off, in which case rendering is bit-exact with the legacy
/// point-source path (the parity oracle depends on this).
#[derive(Clone, Copy, Debug)]
pub struct Source {
    pub position: Vec3,
    /// Linear pre-gain applied to this source's input.
    pub gain: f32,
    /// Reverb send level (0..1) into the late-reverb bus.
    pub send: f32,
    /// World-space emission axis (need not be unit length). Zero vector ⇒ omni regardless
    /// of `directivity`. Mirrored per-axis for image sources (correct ISM treatment).
    pub facing: Vec3,
    /// Radiation-pattern amount 0..1: 0 = omni, 1 = cardioid-like. Frequency-dependent —
    /// at 1.0 the broadband rear level is −12 dB and the per-path one-pole darkens behind
    /// the source (high frequencies beam harder than lows, like a talker or speaker).
    pub directivity: f32,
    /// Source radius in metres, 0 = point. Renders the direct path as the centre voice plus
    /// [`EXTENT_TAPS`] decorrelated satellites on a tetrahedron of this radius. Reflections
    /// and the late-reverb send keep treating the source as its centre point.
    pub extent: f32,
}
impl Source {
    pub fn new(position: Vec3, gain: f32) -> Source {
        Source {
            position,
            gain,
            send: 0.35,
            facing: Vec3::new(0.0, 0.0, 0.0),
            directivity: 0.0,
            extent: 0.0,
        }
    }
    /// Give the source a radiation pattern: `facing` is the world-space emission axis,
    /// `directivity` the pattern amount (0 = omni .. 1 = cardioid-like).
    pub fn with_directivity(mut self, facing: Vec3, directivity: f32) -> Source {
        self.facing = facing;
        self.directivity = directivity;
        self
    }
    /// Give the source a physical radius in metres (0 = point source).
    pub fn with_extent(mut self, radius: f32) -> Source {
        self.extent = radius;
        self
    }
}

struct Room {
    dims: [f32; 3],
    reflection_order: u32,
    wall_absorption: f32,
    /// Per-surface 3-band absorption, surfaces [+x, -x, +y, -y, +z, -z], bands [low, mid, high].
    surface_abs: [[f32; 3]; 6],
    wet: f32,
    backend: ReverbBackend,
    ir_left: Vec<f32>,
    ir_right: Vec<f32>,
}

impl Room {
    fn from_preset(p: &RoomPreset) -> Room {
        Room {
            dims: p.dims,
            reflection_order: p.reflection_order,
            wall_absorption: p.wall_absorption,
            surface_abs: p.surface_abs,
            wet: p.wet,
            backend: p.backend,
            ir_left: p.ir_left.clone(),
            ir_right: p.ir_right.clone(),
        }
    }
    fn dry() -> Room {
        Room {
            dims: [8.0, 4.0, 10.0],
            reflection_order: 0,
            wall_absorption: 1.0,
            surface_abs: [[1.0; 3]; 6],
            wet: 0.0,
            backend: ReverbBackend::Fdn,
            ir_left: Vec::new(),
            ir_right: Vec::new(),
        }
    }
}

pub struct Renderer {
    sr: f32,
    db: HrtfDb,
    max_sources: usize,
    max_block: usize,

    direct: Vec<Voice>,
    reflect: Vec<Voice>, // max_sources * REFLECT_PER_SOURCE (stable per-source slots)
    // Volumetric-extent satellites: max_sources * EXTENT_TAPS stable slots, each with its
    // own velvet-noise decorrelator. Idle (and free) while a source's extent is 0.
    spread: Vec<Voice>,
    decor: Vec<Decorrelator>,
    refl_taps: usize,
    reflections_enabled: bool,
    src_dist: Vec<f32>,
    silence: Vec<f32>,

    fdn: Fdn,
    conv: Option<ConvReverb>,
    /// Late-tail blend for rooms that have a BRIR: 0 = pure parametric FDN, 1 = pure measured
    /// BRIR. Equal-power crossfade. No effect on rooms without an IR (always FDN).
    reverb_blend: f32,
    rooms: Vec<Room>,
    cur_room: usize,
    room: Room,

    // smoothed head orientation
    head: Quat,
    head_pos: Vec3,
    first: bool,

    // "an agent is waiting" attention cue (synthesized in-core, spatialized like a voice)
    attn: AttentionCue,
    attn_voice: Voice,
    attn_buf: Vec<f32>,

    // preallocated scratch
    send_bus: Vec<f32>,
    rev_l: Vec<f32>,
    rev_r: Vec<f32>,
    spread_buf: Vec<f32>, // decorrelated satellite input for the current (source, tap)
    hrir_l: Vec<f32>,
    hrir_r: Vec<f32>,
    // frequency-scaled HRIR scratch (single-parameter HRTF personalization / "fit")
    warp_l: Vec<f32>,
    warp_r: Vec<f32>,
    /// Frequency-scaling factor for the direct-path HRIR (Middlebrooks). 1.0 = the baked HRTF;
    /// >1 shifts the pinna spectral cues UP (smaller head/pinna than the dummy head), <1 down.
    /// Tunes the median-plane / front-back cue that a non-individual HRTF gets wrong.
    freq_scale: f32,

    master_gain: f32,

    // Eyes/immersion fade, applied PER-SOURCE inside the engine (not a master multiply): scene
    // sources scale by `immersion`, the attention cue by `1 − immersion`. One shared reverb, so the
    // scene's tail rings out naturally as its sends fade. Smoothed per block (τ≈0.25 s). Default 1.0
    // ⇒ every source ×1.0 ⇒ bit-exact with the pre-immersion path (parity oracle unaffected).
    immersion: f32,
    immersion_target: f32,
}

impl Renderer {
    /// Create a renderer from a parsed asset. `max_block` bounds the largest block
    /// passed to [`Renderer::process`]; all scratch is sized here.
    pub fn new(asset: &AntiphonAsset, sample_rate: f32, max_sources: usize, max_block: usize) -> Renderer {
        let hrir_len = asset.hrir_len;
        let db = HrtfDb::from_asset(asset);
        let max_predelay = (40.0 / SPEED_OF_SOUND * sample_rate) as usize + 16; // up to ~40 m extra path

        let mut direct = Vec::with_capacity(max_sources);
        for _ in 0..max_sources {
            direct.push(Voice::new(hrir_len, MAX_ITD_SAMPLES, 1));
        }
        let refl_taps = hrir_len.min(REFL_TAPS);
        let mut reflect = Vec::with_capacity(max_sources * REFLECT_PER_SOURCE);
        for _ in 0..max_sources * REFLECT_PER_SOURCE {
            reflect.push(Voice::new(refl_taps, MAX_ITD_SAMPLES, max_predelay));
        }

        // Volumetric-extent satellites: full-length HRIR (direct-path timbre matters), a
        // pre-delay line sized for the largest extent-induced path difference, and a
        // per-slot decorrelator (~24 ms velvet noise, deterministic seed per slot).
        let sat_predelay = (MAX_EXTENT / SPEED_OF_SOUND * sample_rate) as usize + 16;
        let decor_span = (0.024 * sample_rate) as usize;
        let mut spread = Vec::with_capacity(max_sources * EXTENT_TAPS);
        let mut decor = Vec::with_capacity(max_sources * EXTENT_TAPS);
        for i in 0..max_sources * EXTENT_TAPS {
            spread.push(Voice::new(hrir_len, MAX_ITD_SAMPLES, sat_predelay));
            decor.push(Decorrelator::new(0x51ED_2701 ^ (i as u32), decor_span));
        }

        let mut rooms = Vec::new();
        for p in &asset.rooms {
            rooms.push(Room::from_preset(p));
        }

        let mut fdn = Fdn::new(sample_rate);
        let (room, conv) = if let Some(p) = asset.rooms.first() {
            let r = Room::from_preset(p);
            fdn.configure(p.rt60[1], p.rt60[2], p.dims, p.wet);
            let c = build_conv(&r, max_block, fdn.t_mix_samples());
            (r, c)
        } else {
            (Room::dry(), None)
        };

        Renderer {
            sr: sample_rate,
            db,
            max_sources,
            max_block,
            direct,
            reflect,
            spread,
            decor,
            refl_taps,
            reflections_enabled: true,
            src_dist: vec![1.0; max_sources],
            silence: vec![0.0; max_block],
            fdn,
            conv,
            reverb_blend: 1.0, // default: rooms with a BRIR play the measured tail (current behaviour)
            rooms,
            cur_room: 0,
            room,
            head: Quat::IDENTITY,
            head_pos: Vec3::default(),
            first: true,
            attn: AttentionCue::new(sample_rate, 0x9E37_79B9, AttentionCfg::default()),
            attn_voice: Voice::new(hrir_len, MAX_ITD_SAMPLES, 1),
            attn_buf: vec![0.0; max_block],
            send_bus: vec![0.0; max_block],
            rev_l: vec![0.0; max_block],
            rev_r: vec![0.0; max_block],
            spread_buf: vec![0.0; max_block],
            hrir_l: vec![0.0; hrir_len],
            hrir_r: vec![0.0; hrir_len],
            warp_l: vec![0.0; hrir_len],
            warp_r: vec![0.0; hrir_len],
            freq_scale: 1.0,
            master_gain: 1.0,
            immersion: 1.0,
            immersion_target: 1.0,
        }
    }

    pub fn num_rooms(&self) -> usize {
        self.rooms.len()
    }
    /// Dimensions `[w, h, d]` in metres of room preset `idx`, or `None` if out of range.
    /// The room is placed x/z-centred on the origin with the floor at `y = -EAR_HEIGHT_M`.
    pub fn room_dims(&self, idx: usize) -> Option<[f32; 3]> {
        self.rooms.get(idx).map(|r| r.dims)
    }
    pub fn current_room(&self) -> usize {
        self.cur_room
    }
    pub fn sample_rate(&self) -> f32 {
        self.sr
    }
    pub fn set_master_gain(&mut self, g: f32) {
        self.master_gain = g;
    }
    /// Number of agents waiting for attention. 0 silences the cue and resets its build clock.
    pub fn set_attention_agents(&mut self, n: u32) {
        self.attn.set_agents(n);
    }
    /// Minutes over which the attention cue ramps from silent → full urgency (louder + faster).
    pub fn set_attention_build_minutes(&mut self, m: f32) {
        self.attn.set_build_minutes(m);
    }
    /// Immersion (eyes) fade target, 0..1: 1 = eyes-closed/scene full & cue silent, 0 = eyes-open/
    /// scene silent & cue audible. Smoothed internally, applied per-source. Hosts set the target;
    /// the crossfade between the scene and the attention cue is automatic.
    pub fn set_immersion(&mut self, target: f32) {
        self.immersion_target = target.clamp(0.0, 1.0);
    }
    /// Current (smoothed) immersion value — for host UI/debug readouts.
    pub fn immersion(&self) -> f32 {
        self.immersion
    }
    pub fn set_reflections_enabled(&mut self, on: bool) {
        self.reflections_enabled = on;
    }
    /// Late-tail blend for BRIR rooms: 0 = pure parametric FDN, 1 = pure measured BRIR.
    pub fn set_reverb_blend(&mut self, b: f32) {
        self.reverb_blend = b.clamp(0.0, 1.0);
    }
    /// HRTF frequency-scaling / "fit" (Middlebrooks): 1.0 = baked HRTF; >1 shifts pinna cues up
    /// (smaller head/pinna), <1 down. Personalizes the median-plane / front-back cue by ear.
    pub fn set_freq_scale(&mut self, s: f32) {
        self.freq_scale = s.clamp(0.5, 2.2);
    }

    /// Select a room preset by index (clamped). Reconfigures the reverb.
    pub fn set_room(&mut self, idx: usize) {
        if self.rooms.is_empty() {
            return;
        }
        let idx = idx.min(self.rooms.len() - 1);
        self.cur_room = idx;
        let src = &self.rooms[idx];
        self.room = Room {
            dims: src.dims,
            reflection_order: src.reflection_order,
            wall_absorption: src.wall_absorption,
            surface_abs: src.surface_abs,
            wet: src.wet,
            backend: src.backend,
            ir_left: src.ir_left.clone(),
            ir_right: src.ir_right.clone(),
        };
        self.fdn.configure_from(self.room.dims, self.room.wet);
        self.fdn.reset();
        self.conv = build_conv(&self.room, self.max_block, self.fdn.t_mix_samples());
    }

    /// Render one block. `inputs[i]` is the mono signal for `sources[i]`; each must be
    /// `frames` long. Output is written (overwriting) to `out_l`/`out_r`.
    pub fn process(
        &mut self,
        pose: &Pose,
        sources: &[Source],
        inputs: &[&[f32]],
        out_l: &mut [f32],
        out_r: &mut [f32],
        frames: usize,
    ) {
        let n = sources.len().min(self.max_sources).min(inputs.len());

        // clear output + buses
        for i in 0..frames {
            out_l[i] = 0.0;
            out_r[i] = 0.0;
            self.send_bus[i] = 0.0;
            self.rev_l[i] = 0.0;
            self.rev_r[i] = 0.0;
        }

        // smooth head orientation (click-free) toward the requested pose
        if self.first {
            self.head = pose.orientation;
            self.head_pos = pose.position;
            self.first = false;
        } else {
            self.head = self.head.nlerp(pose.orientation, 0.5);
            let a = 0.5;
            self.head_pos = Vec3::new(
                self.head_pos.x + a * (pose.position.x - self.head_pos.x),
                self.head_pos.y + a * (pose.position.y - self.head_pos.y),
                self.head_pos.z + a * (pose.position.z - self.head_pos.z),
            );
        }
        let inv_head = self.head.conjugate();

        let send_slice = &mut self.send_bus[..frames];

        // Energy-conserving FDN send: with the diffuse tail delayed to t_mix, scale the send so
        // its onset matches the reverberant field at t_mix (no double-counting). The convolution
        // backend carries its own early+late in one IR, so it keeps the raw send.
        let fdn = matches!(self.room.backend, ReverbBackend::Fdn);
        let send_scale = if fdn { self.fdn.send_scale() } else { 1.0 };

        // Eyes/immersion fade (per-block one-pole, τ≈0.25 s). Scene sources scale by `imm`; the
        // attention cue by `cue_gate = 1 − imm`, so opening your eyes crossfades scene→cue through
        // the one shared reverb. `imm` defaults to 1.0 ⇒ every scene multiply is ×1.0 (bit-exact).
        let imm_coef = 1.0 - (-(frames as f32) / (0.25 * self.sr)).exp();
        self.immersion += (self.immersion_target - self.immersion) * imm_coef;
        let imm = self.immersion;
        let cue_gate = 1.0 - imm;

        for i in 0..n {
            let src = sources[i];
            let inp = &inputs[i][..frames];

            // listener-relative geometry for the direct path
            let world = src.position.sub(self.head_pos);
            let rel = inv_head.rotate(world);
            let dist = rel.len().max(1e-4);
            let dir = rel.normalized();
            self.src_dist[i] = dist;

            // Radiation pattern (omni when directivity == 0 or facing is the zero vector).
            // Everything below multiplies by exactly 1.0 in the omni case — bit-exact.
            let d_amt = if src.facing.len() > 1e-6 { src.directivity.clamp(0.0, 1.0) } else { 0.0 };
            let facing = src.facing.normalized();
            let emit = self.head_pos.sub(src.position).normalized(); // source → listener
            let (g_dir, lp_dir) = directivity_gain(facing.dot(emit), d_amt);
            // Keep the ROOM's energy independent of facing: the reverb send taps the dry signal
            // post-gain (post-pattern), so divide the pattern back out of the send and apply the
            // pattern's diffuse-field average instead. Behind a directional source the wet/dry
            // ratio then rises — the real-world "they turned away" cue.
            let send_comp = if d_amt > 0.0 { (1.0 - 0.42 * d_amt) / g_dir.max(0.2) } else { 1.0 };

            // Volumetric extent: the centre voice and satellites split the source power.
            let ext = src.extent.clamp(0.0, MAX_EXTENT);
            let m = ext / (ext + 0.35); // 0 = point → 1 = large; smooth through extent = 0
            let centre_g = (1.0 - 0.8 * m).sqrt();
            let sat_g = (0.8 * m / EXTENT_TAPS as f32).sqrt();

            let dgain = src.gain * distance_atten(dist) * imm * g_dir * centre_g;
            let lp_a = (air_lp(dist) * lp_dir).clamp(0.05, 1.0);
            let itd = self.db.interp(dir, &mut self.hrir_l, &mut self.hrir_r);

            // HRTF fit: frequency-scale the direct-path HRIR. Bypassed (bit-exact) at 1.0, so the
            // default rendering and the parity oracle are unchanged.
            let (hl, hr): (&[f32], &[f32]) = if (self.freq_scale - 1.0).abs() > 1.0e-4 {
                resample_hrir(&self.hrir_l, &mut self.warp_l, self.freq_scale);
                resample_hrir(&self.hrir_r, &mut self.warp_r, self.freq_scale);
                (&self.warp_l, &self.warp_r)
            } else {
                (&self.hrir_l, &self.hrir_r)
            };
            self.direct[i].set_target(hl, hr, itd, dgain, lp_a, 0.0, false);
            // Near-field DVF: derive each ear's incidence angle from the SAME `dir` as the ITD
            // (cos θ_right = dir.x, cos θ_left = −dir.x — pinned to the +x-right ear axis, so it
            // can't flip L/R). rho = r / head-radius. Identity beyond ~1 m → far field unchanged.
            let rho = dist / 0.0875;
            let theta_r = dir.x.clamp(-1.0, 1.0).acos().to_degrees();
            let theta_l = (-dir.x).clamp(-1.0, 1.0).acos().to_degrees();
            self.direct[i].set_dvf(
                dvf::near_field_shelf(theta_l, rho, self.sr),
                dvf::near_field_shelf(theta_r, rho, self.sr),
                false,
            );
            self.direct[i].process(
                inp,
                out_l,
                out_r,
                send_slice,
                src.send * send_scale * imm * send_comp,
            );

            // Satellite taps (extent > 0 only): decorrelated copies of the input, spread over
            // a tetrahedron of radius `ext`, each with its own geometry (ITD/HRIR/DVF), a true
            // geometric pre-delay for taps farther than the centre, and the same radiation
            // pattern evaluated at its own emission angle.
            for t in 0..EXTENT_TAPS {
                let slot = i * EXTENT_TAPS + t;
                if ext > 0.0 {
                    let off = EXTENT_OFFSETS[t];
                    let spos = Vec3::new(
                        src.position.x + off[0] * ext,
                        src.position.y + off[1] * ext,
                        src.position.z + off[2] * ext,
                    );
                    let srel = inv_head.rotate(spos.sub(self.head_pos));
                    let sdist = srel.len().max(1e-4);
                    let sdir = srel.normalized();
                    let semit = self.head_pos.sub(spos).normalized();
                    let (sg_dir, slp_dir) = directivity_gain(facing.dot(semit), d_amt);
                    let sgain = src.gain * distance_atten(sdist) * imm * sg_dir * sat_g;
                    let slp = (air_lp(sdist) * slp_dir).clamp(0.05, 1.0);
                    let spred = (sdist - dist).max(0.0) / SPEED_OF_SOUND * self.sr;
                    let sitd = self.db.interp(sdir, &mut self.hrir_l, &mut self.hrir_r);
                    let (hl, hr): (&[f32], &[f32]) = if (self.freq_scale - 1.0).abs() > 1.0e-4 {
                        resample_hrir(&self.hrir_l, &mut self.warp_l, self.freq_scale);
                        resample_hrir(&self.hrir_r, &mut self.warp_r, self.freq_scale);
                        (&self.warp_l, &self.warp_r)
                    } else {
                        (&self.hrir_l, &self.hrir_r)
                    };
                    // stale decorrelator state from a previous activation must not leak in
                    if !self.spread[slot].active {
                        self.decor[slot].clear();
                    }
                    self.spread[slot].set_target(hl, hr, sitd, sgain, slp, spred, false);
                    let srho = sdist / 0.0875;
                    let stheta_r = sdir.x.clamp(-1.0, 1.0).acos().to_degrees();
                    let stheta_l = (-sdir.x).clamp(-1.0, 1.0).acos().to_degrees();
                    self.spread[slot].set_dvf(
                        dvf::near_field_shelf(stheta_l, srho, self.sr),
                        dvf::near_field_shelf(stheta_r, srho, self.sr),
                        false,
                    );
                    for j in 0..frames {
                        self.spread_buf[j] = self.decor[slot].tick(inp[j]);
                    }
                    self.spread[slot].process(
                        &self.spread_buf[..frames],
                        out_l,
                        out_r,
                        send_slice,
                        src.send * send_scale * imm * send_comp,
                    );
                } else if self.spread[slot].active {
                    // ramp to silence over one block (reflection-style click-free fade)
                    self.spread[slot].set_target(&self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false);
                    self.spread[slot].process(&self.silence[..frames], out_l, out_r, send_slice, 0.0);
                    self.spread[slot].active = false;
                }
            }
        }

        // deactivate unused voices (ramp to silence next block if reused)
        for i in n..self.max_sources {
            if self.direct[i].active {
                self.direct[i].set_target(
                    &self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false,
                );
                self.direct[i].active = false;
            }
            for t in 0..EXTENT_TAPS {
                let slot = i * EXTENT_TAPS + t;
                if self.spread[slot].active {
                    self.spread[slot].set_target(&self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false);
                    self.spread[slot].process(&self.silence[..frames], out_l, out_r, send_slice, 0.0);
                    self.spread[slot].active = false;
                }
            }
        }

        // ---- "an agent is waiting" attention cue ----
        // Synthesized in-core, then run through the SAME direct-path pipeline (near-field DVF +
        // reverb send) as a voice. Its position is head-relative (glued to one ear), so we feed the
        // local offset straight in as `rel` — no world→head rotation. Defaults to 0 agents (silent),
        // so the parity oracle and existing renders are bit-unchanged.
        if self.attn.needs_render() {
            self.attn.render(&mut self.attn_buf[..frames], frames);
            let local = Vec3::new(self.attn.ear_sign() * self.attn.distance(), 0.0, -0.03);
            let dist = local.len().max(1e-4);
            let dir = local.normalized();
            // cue rides the INVERSE of immersion: audible when the scene is faded out (eyes open)
            let dgain = self.attn.gain() * distance_atten(dist) * cue_gate;
            let lp_a = air_lp(dist);
            let itd = self.db.interp(dir, &mut self.hrir_l, &mut self.hrir_r);
            self.attn_voice.set_target(&self.hrir_l, &self.hrir_r, itd, dgain, lp_a, 0.0, false);
            let rho = dist / 0.0875;
            let theta_r = dir.x.clamp(-1.0, 1.0).acos().to_degrees();
            let theta_l = (-dir.x).clamp(-1.0, 1.0).acos().to_degrees();
            self.attn_voice.set_dvf(
                dvf::near_field_shelf(theta_l, rho, self.sr),
                dvf::near_field_shelf(theta_r, rho, self.sr),
                false,
            );
            self.attn_voice
                .process(&self.attn_buf[..frames], out_l, out_r, send_slice, self.attn.send() * send_scale * cue_gate);
        } else if self.attn_voice.active {
            self.attn_voice.set_target(&self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false);
            self.attn_voice.active = false;
        }

        // ---- image-source early reflections (order 1..2, energy-ranked budget) ----
        if self.reflections_enabled && self.room.reflection_order >= 1 {
            let order = self.room.reflection_order;
            let surf = self.room.surface_abs;
            // Hand the discrete reflections off to the late tail at the mixing time: the ISM owns
            // [0, t_mix], the late stage owns [t_mix, ∞). Equal-power fade-out across
            // t_mix..1.5·t_mix (click-free), complementary to the late stage's fade-in — for the
            // FDN (pre-delayed to t_mix) AND the BRIR (gated to its late tail by build_conv, so the
            // translating ISM provides the early reflections the fixed BRIR can't).
            let win_edge = self.fdn.t_mix_samples();
            let win_trans = (0.5 * win_edge).max(1.0);

            let head_pos = self.head_pos;
            let dims = self.room.dims;
            let per = REFLECT_PER_SOURCE;
            // Each source owns a fixed slot range. We keep the K LOUDEST images, ranked by a
            // listener-independent energy proxy (mid-band path gain / distance from the origin —
            // the listener's nominal spot: x/z room centre at ear height), so the image→slot map
            // is stable as the listener moves — no reshuffle clicks. Fixed-size top-K insertion:
            // no alloc, deterministic.
            for i in 0..n {
                let s = sources[i].position;
                let gain = sources[i].gain;
                let direct_dist = self.src_dist[i];

                // Radiation pattern for this source's images: the facing axis is mirrored by
                // the same wall reflections as the position (per-axis sign = bounce-count
                // parity — the correct image-source treatment of a directional source).
                let d_amt = if sources[i].facing.len() > 1e-6 {
                    sources[i].directivity.clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let facing = sources[i].facing.normalized();
                let mirrored = |bounces: &[u32; 6]| -> Vec3 {
                    let sg = |a: u32, b: u32| if (a + b) & 1 == 1 { -1.0f32 } else { 1.0 };
                    Vec3::new(
                        facing.x * sg(bounces[0], bounces[1]),
                        facing.y * sg(bounces[2], bounces[3]),
                        facing.z * sg(bounces[4], bounces[5]),
                    )
                };

                // (pos, order, per-surface bounces, energy proxy), held descending by energy.
                let mut imgs =
                    [(Vec3::new(0.0, 0.0, 0.0), 0u32, [0u32; 6], f32::NEG_INFINITY); REFLECT_PER_SOURCE];
                let mut count = 0usize;
                shoebox_images(s, dims, order, |pos, ord, bounces| {
                    let g = band_gain(&surf, &bounces);
                    // Directivity enters the proxy via the emission angle toward the ORIGIN
                    // (the listener's nominal spot) — listener-independent, so the
                    // image→slot map still never reshuffles as the head moves.
                    let g_dir = directivity_gain(
                        mirrored(&bounces).dot(Vec3::new(-pos.x, -pos.y, -pos.z).normalized()),
                        d_amt,
                    )
                    .0;
                    let e = g[1] * g_dir / pos.len().max(0.1); // mid-band, listener-independent
                    if count < per {
                        imgs[count] = (pos, ord, bounces, e);
                        let mut j = count;
                        while j > 0 && imgs[j].3 > imgs[j - 1].3 {
                            imgs.swap(j, j - 1);
                            j -= 1;
                        }
                        count += 1;
                    } else if e > imgs[per - 1].3 {
                        imgs[per - 1] = (pos, ord, bounces, e);
                        let mut j = per - 1;
                        while j > 0 && imgs[j].3 > imgs[j - 1].3 {
                            imgs.swap(j, j - 1);
                            j -= 1;
                        }
                    }
                });

                for k in 0..per {
                    let slot = i * per + k;
                    if k < count {
                        let (pos, _ord, bounces, _e) = imgs[k];
                        let rel = inv_head.rotate(pos.sub(head_pos));
                        let idist = rel.len().max(0.05);
                        let idir = rel.normalized();
                        let predelay = (idist - direct_dist).max(0.0) / SPEED_OF_SOUND * self.sr;
                        // per-surface, 3-band reflection gain. Mid band sets the broadband level;
                        // the high/mid ratio darkens the one-pole so carpet-heavy paths roll off
                        // HF more (LF-vs-mid shelf is a later refinement).
                        let g = band_gain(&surf, &bounces);
                        // equal-power fade-out as arrival crosses t_mix (late stage takes over)
                        let f = ((predelay - win_edge) / win_trans).clamp(0.0, 1.0);
                        let win = (1.0 - f).sqrt();
                        // radiation pattern at this image's true emission angle (toward the
                        // listener, facing mirrored by the reflection parity)
                        let (ig_dir, ilp_dir) = directivity_gain(
                            mirrored(&bounces).dot(head_pos.sub(pos).normalized()),
                            d_amt,
                        );
                        let igain = gain * g[1] * distance_atten(idist) * win * imm * ig_dir;
                        let hf_tilt = if g[1] > 1e-6 { (g[2] / g[1]).clamp(0.05, 1.0) } else { 1.0 };
                        let ilp = (air_lp(idist) * hf_tilt * ilp_dir).clamp(0.05, 1.0);
                        let rt = self.refl_taps;
                        let iitd = self.db.interp(idir, &mut self.hrir_l, &mut self.hrir_r);
                        self.reflect[slot].set_target(
                            &self.hrir_l[..rt], &self.hrir_r[..rt], iitd, igain, ilp, predelay, false,
                        );
                        let inp = &inputs[i][..frames];
                        self.reflect[slot].process(inp, out_l, out_r, send_slice, 0.0);
                    } else if self.reflect[slot].active {
                        let rt = self.refl_taps;
                        self.reflect[slot].set_target(&self.hrir_l[..rt], &self.hrir_r[..rt], 0.0, 0.0, 1.0, 0.0, false);
                        self.reflect[slot].process(&self.silence[..frames], out_l, out_r, send_slice, 0.0);
                        self.reflect[slot].active = false;
                    }
                }
            }
            // silence reflection slots belonging to now-inactive sources
            let rt = self.refl_taps;
            for i in n..self.max_sources {
                for k in 0..per {
                    let slot = i * per + k;
                    if self.reflect[slot].active {
                        self.reflect[slot].set_target(&self.hrir_l[..rt], &self.hrir_r[..rt], 0.0, 0.0, 1.0, 0.0, false);
                        self.reflect[slot].process(&self.silence[..frames], out_l, out_r, send_slice, 0.0);
                        self.reflect[slot].active = false;
                    }
                }
            }
        }

        // ---- late reverb: parametric FDN and/or measured-BRIR convolution ----
        if self.room.wet > 0.0 {
            let (rl, rr) = (&mut self.rev_l[..frames], &mut self.rev_r[..frames]);
            for i in 0..frames {
                rl[i] = 0.0;
                rr[i] = 0.0;
            }
            // Rooms with a BRIR can blend the two late tails (FDN's smooth even density vs. the
            // BRIR's measured character), equal-power. Rooms without an IR are always pure FDN.
            if self.conv.is_some() {
                let b = self.reverb_blend.clamp(0.0, 1.0);
                let g_fdn = (1.0 - b).sqrt();
                if g_fdn > 1.0e-4 {
                    self.fdn.process(send_slice, rl, rr, g_fdn);
                }
                self.conv.as_mut().unwrap().process(send_slice, rl, rr, b.sqrt());
            } else {
                self.fdn.process(send_slice, rl, rr, 1.0);
            }
            for i in 0..frames {
                out_l[i] += rl[i];
                out_r[i] += rr[i];
            }
        }

        // ---- master gain + soft limiter ----
        let g = self.master_gain;
        let limit = 0.98f32;
        for i in 0..frames {
            out_l[i] = soft_limit(out_l[i] * g, limit);
            out_r[i] = soft_limit(out_r[i] * g, limit);
        }
    }
}


/// Build a convolution reverb for a room if it uses a BRIR; otherwise None.
fn build_conv(room: &Room, max_block: usize, t_mix_samp: f32) -> Option<ConvReverb> {
    if room.backend == ReverbBackend::Convolution && !room.ir_left.is_empty() {
        // B0 (report 06 §4): keep the measured BRIR for the DIFFUSE LATE TAIL only. Its early
        // reflections are baked at one listening point and don't translate; the analytic ISM
        // (which does translate with the listener) now owns the early part. Fade the IR in across
        // the mixing time, equal-power-complementary to the ISM fade-OUT, so they cross at t_mix.
        let win_late = |ir: &[f32]| -> Vec<f32> {
            let edge = t_mix_samp;
            let trans = (0.5 * t_mix_samp).max(1.0);
            ir.iter()
                .enumerate()
                .map(|(j, &v)| {
                    let f = ((j as f32 - edge) / trans).clamp(0.0, 1.0);
                    v * f.sqrt() // equal-power fade-in (complements ISM's sqrt fade-out)
                })
                .collect()
        };
        let irl = win_late(&room.ir_left);
        let irr = win_late(&room.ir_right);
        Some(ConvReverb::new(128, &irl, &irr, room.wet, max_block))
    } else {
        None
    }
}

/// Frequency-scale a min-phase HRIR by resampling it (time scaling = linear frequency-axis
/// scaling, which IS Middlebrooks' frequency warp). `beta > 1` compresses in time → pinna notches
/// move UP. Energy-normalized so the level (and the separate ITD) are unchanged. Deterministic.
fn resample_hrir(src: &[f32], dst: &mut [f32], beta: f32) {
    let n = src.len();
    let mut e_in = 0.0f32;
    for &v in src {
        e_in += v * v;
    }
    for (i, d) in dst.iter_mut().enumerate().take(n) {
        let sp = i as f32 * beta;
        let i0 = sp.floor() as isize;
        let frac = sp - i0 as f32;
        let a = if i0 >= 0 && (i0 as usize) < n { src[i0 as usize] } else { 0.0 };
        let b = if i0 + 1 >= 0 && ((i0 + 1) as usize) < n { src[(i0 + 1) as usize] } else { 0.0 };
        *d = a + (b - a) * frac;
    }
    let mut e_out = 0.0f32;
    for d in dst.iter().take(n) {
        e_out += *d * *d;
    }
    if e_out > 1.0e-12 {
        let g = (e_in / e_out).sqrt();
        for d in dst.iter_mut().take(n) {
            *d *= g;
        }
    }
}

/// Frequency-dependent first-order radiation pattern for one propagation path.
/// `cos_theta` = cosine of the angle between the source's facing axis and the path's
/// emission direction; `d` = directivity amount 0..1. Returns `(broadband gain,
/// one-pole coefficient multiplier)`. At `d == 1` the broadband rear level is −12 dB and
/// the one-pole coefficient drops to ×0.3 behind the source (high frequencies beam harder
/// than lows — behind a talker is quieter AND darker). Exactly `(1.0, 1.0)` at `d == 0`,
/// so omni sources are bit-exact with the pre-directivity path.
#[inline]
fn directivity_gain(cos_theta: f32, d: f32) -> (f32, f32) {
    if d <= 0.0 {
        return (1.0, 1.0);
    }
    let rear = 1.0 - 0.5 * (1.0 + cos_theta.clamp(-1.0, 1.0)); // 0 on-axis → 1 behind
    let g = 1.0 - d * rear * 0.75;
    let lp = 1.0 - d * rear * 0.7;
    (g, lp.clamp(0.05, 1.0))
}

#[inline]
fn distance_atten(dist: f32) -> f32 {
    // 1/r with a near-field floor; mild near-field boost below the reference distance.
    let r = dist.max(0.3);
    (1.0 / r).min(3.5)
}

#[inline]
fn air_lp(dist: f32) -> f32 {
    // crude distance-dependent air absorption (one-pole coeff; 1.0 = open)
    (1.0 - dist * 0.012).clamp(0.25, 1.0)
}

#[inline]
fn soft_limit(x: f32, limit: f32) -> f32 {
    // tanh soft clip, transparent below the limit
    limit * (x / limit).tanh()
}

/// 3-band reflection gain for an image: the product over surfaces of `(1 - absorption)^bounces`,
/// per band. Deterministic (`powi`, no transcendentals) → parity-safe. `surf` surfaces are
/// `[+x, -x, +y, -y, +z, -z]`, bands `[low, mid, high]`.
#[inline]
fn band_gain(surf: &[[f32; 3]; 6], bounces: &[u32; 6]) -> [f32; 3] {
    let mut g = [1.0f32; 3];
    for s in 0..6 {
        let n = bounces[s] as i32;
        if n == 0 {
            continue;
        }
        for b in 0..3 {
            g[b] *= (1.0 - surf[s][b]).max(0.0).powi(n);
        }
    }
    g
}

/// Bounce counts per surface `[+x, -x, +y, -y, +z, -z]` for a shoebox image with mirror indices
/// `(mx, my, mz)`. Along each axis the image undergoes `|m|` reflections alternating between the
/// two walls; we split them evenly, giving the leftover (odd) bounce to the wall on the side the
/// image is mirrored toward. Deterministic — only matters when the two walls differ (floor vs
/// ceiling) — and parity-safe.
fn surface_bounces(mx: i32, my: i32, mz: i32) -> [u32; 6] {
    // returns (neg_wall_bounces, pos_wall_bounces) for one axis
    let split = |m: i32| -> (u32, u32) {
        let a = m.unsigned_abs();
        let (h, odd) = (a / 2, a % 2);
        if odd == 0 {
            (h, h)
        } else if m > 0 {
            (h, h + 1) // mirrored toward +: extra bounce on the + wall
        } else {
            (h + 1, h)
        }
    };
    let (xn, xp) = split(mx);
    let (yn, yp) = split(my);
    let (zn, zp) = split(mz);
    [xp, xn, yp, yn, zp, zn] // [+x, -x, +y, -y, +z, -z]
}

/// Enumerate shoebox image sources up to `order` for a room x/z-centred on the origin with
/// the listener's ears [`EAR_HEIGHT_M`] above the floor (floor at `y = -EAR_HEIGHT_M`,
/// ceiling at `y = dims[1] - EAR_HEIGHT_M`). For a 1-D room centred at the origin the image
/// of source `s` is `m*L + (-1)^m * s`. On y the room centre sits at `oy = L/2 - EAR_HEIGHT_M`
/// (possibly negative for low rooms — still valid): reflecting in room-centred coordinates
/// and translating back gives even-m images unchanged (`m*L + s`) and odd-m images at
/// `m*L - s + 2*oy`. The 3-D images are the product, with reflection order `|mx|+|my|+|mz|`.
/// Calls `push(pos, order, surface_bounces)` for each image (excluding the direct path, order 0).
fn shoebox_images(s: Vec3, dims: [f32; 3], order: u32, mut push: impl FnMut(Vec3, u32, [u32; 6])) {
    let o = order as i32;
    let (lx, ly, lz) = (dims[0], dims[1], dims[2]);
    let oy = 0.5 * ly - EAR_HEIGHT_M; // room centre height above the listener's ears
    let axis = |m: i32, l: f32, c: f32| m as f32 * l + if m & 1 == 0 { c } else { -c };
    let axis_y = |m: i32| m as f32 * ly + if m & 1 == 0 { s.y } else { 2.0 * oy - s.y };
    for target in 1..=o {
        for mx in -o..=o {
            for my in -o..=o {
                for mz in -o..=o {
                    if mx.abs() + my.abs() + mz.abs() != target {
                        continue;
                    }
                    push(
                        Vec3::new(axis(mx, lx, s.x), axis_y(my), axis(mz, lz, s.z)),
                        target as u32,
                        surface_bounces(mx, my, mz),
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use antiphon_assets::{AssetBuilder, ReverbBackend, RoomPreset};

    // A tiny 2-direction asset (front + right) is enough to exercise the pipeline.
    fn tiny_asset() -> AntiphonAsset {
        let mut b = AssetBuilder::new(48000.0, 8);
        let imp = |d: usize, amp: f32| {
            let mut v = vec![0.0f32; 8];
            v[d] = amp;
            v
        };
        // front (balanced), right (right ear louder), left (left ear louder), up, down, back
        b.push_direction(0.0, 0.0, 0.0, &imp(0, 1.0), &imp(0, 1.0));
        b.push_direction(-std::f32::consts::FRAC_PI_2, 0.0, -20.0, &imp(0, 0.25), &imp(2, 1.0));
        b.push_direction(std::f32::consts::FRAC_PI_2, 0.0, 20.0, &imp(2, 1.0), &imp(0, 0.25));
        b.push_direction(0.0, std::f32::consts::FRAC_PI_2, 0.0, &imp(1, 1.0), &imp(1, 1.0));
        b.push_direction(0.0, -std::f32::consts::FRAC_PI_4, 0.0, &imp(1, 1.0), &imp(1, 1.0));
        b.push_direction(std::f32::consts::PI, 0.0, 0.0, &imp(3, 1.0), &imp(3, 1.0));
        b.push_room(RoomPreset {
            name: "room".into(),
            dims: [5.0, 3.0, 6.0],
            rt60: [0.5, 0.4, 0.3],
            wall_absorption: 0.2,
            surface_abs: [[0.13, 0.2, 0.34]; 6],
            reflection_order: 1,
            wet: 0.25,
            backend: ReverbBackend::Fdn,
            ir_left: vec![],
            ir_right: vec![],
        });
        let bytes = b.to_bytes();
        AntiphonAsset::parse(&bytes).unwrap()
    }

    #[test]
    fn renders_finite_and_lateralizes() {
        let a = tiny_asset();
        let mut r = Renderer::new(&a, 48000.0, 1, 128);
        r.set_room(0);
        let inp = vec![0.3f32; 128];
        let mut l = vec![0.0; 128];
        let mut rr = vec![0.0; 128];

        // source hard right
        let src = [Source::new(Vec3::new(2.0, 0.0, 0.0), 1.0)];
        for _ in 0..40 {
            r.process(&Pose::default(), &src, &[&inp], &mut l, &mut rr, 128);
        }
        let el: f32 = l.iter().map(|x| x * x).sum();
        let er: f32 = rr.iter().map(|x| x * x).sum();
        assert!(l.iter().all(|x| x.is_finite()) && rr.iter().all(|x| x.is_finite()));
        assert!(er > el, "right source should be louder in the right ear: L={el} R={er}");
    }

    #[test]
    fn directional_source_rear_is_quieter() {
        let a = tiny_asset();
        let energy = |facing: Vec3| -> f32 {
            let mut r = Renderer::new(&a, 48000.0, 1, 128);
            r.set_room(0);
            r.set_reflections_enabled(false);
            let inp = vec![0.3f32; 128];
            let mut l = vec![0.0; 128];
            let mut rr = vec![0.0; 128];
            // source in front, either facing the listener (+z, toward origin) or away (−z)
            let src = [Source::new(Vec3::new(0.0, 0.0, -2.0), 1.0).with_directivity(facing, 1.0)];
            let mut e = 0.0;
            for it in 0..40 {
                r.process(&Pose::default(), &src, &[&inp], &mut l, &mut rr, 128);
                if it >= 20 {
                    e += l.iter().map(|x| x * x).sum::<f32>() + rr.iter().map(|x| x * x).sum::<f32>();
                }
            }
            e
        };
        let toward = energy(Vec3::new(0.0, 0.0, 1.0));
        let away = energy(Vec3::new(0.0, 0.0, -1.0));
        assert!(toward.is_finite() && away.is_finite());
        // −12 dB broadband + HF darkening behind ⇒ well under half the on-axis energy
        assert!(
            away < toward * 0.5,
            "rear-facing should be much quieter: toward={toward} away={away}"
        );
    }

    #[test]
    fn omni_directivity_zero_is_bit_exact_with_default() {
        let a = tiny_asset();
        let render = |src: Source| -> (Vec<f32>, Vec<f32>) {
            let mut r = Renderer::new(&a, 48000.0, 1, 128);
            r.set_room(0);
            let inp: Vec<f32> = (0..128).map(|i| ((i * 37) % 97) as f32 / 97.0 - 0.5).collect();
            let mut l = vec![0.0; 128];
            let mut rr = vec![0.0; 128];
            for _ in 0..20 {
                r.process(&Pose::from_yaw(0.2), &[src], &[&inp], &mut l, &mut rr, 128);
            }
            (l, rr)
        };
        // explicit facing with directivity 0 and extent 0 must not change a single bit
        let base = render(Source::new(Vec3::new(0.7, 0.1, -1.4), 0.9));
        let tagged = render(
            Source::new(Vec3::new(0.7, 0.1, -1.4), 0.9)
                .with_directivity(Vec3::new(0.0, 0.0, 1.0), 0.0)
                .with_extent(0.0),
        );
        assert_eq!(base.0, tagged.0);
        assert_eq!(base.1, tagged.1);
    }

    #[test]
    fn extended_source_is_finite_and_energy_bounded() {
        let a = tiny_asset();
        let energy = |extent: f32| -> f32 {
            let mut r = Renderer::new(&a, 48000.0, 1, 128);
            r.set_room(0);
            r.set_reflections_enabled(false);
            let inp: Vec<f32> = (0..128).map(|i| ((i * 61) % 127) as f32 / 127.0 - 0.5).collect();
            let mut l = vec![0.0; 128];
            let mut rr = vec![0.0; 128];
            let src = [Source::new(Vec3::new(0.0, 0.0, -2.0), 1.0).with_extent(extent)];
            let mut e = 0.0;
            for it in 0..60 {
                r.process(&Pose::default(), &src, &[&inp], &mut l, &mut rr, 128);
                assert!(l.iter().all(|x| x.is_finite()) && rr.iter().all(|x| x.is_finite()));
                if it >= 30 {
                    e += l.iter().map(|x| x * x).sum::<f32>() + rr.iter().map(|x| x * x).sum::<f32>();
                }
            }
            e
        };
        let point = energy(0.0);
        let wide = energy(1.5);
        assert!(wide > 0.0);
        // power-conserving split: the volumetric render stays within ~6 dB of the point source
        assert!(
            wide > point * 0.25 && wide < point * 4.0,
            "extent should roughly preserve energy: point={point} wide={wide}"
        );
    }

    #[test]
    fn silence_in_silence_out_and_no_nan() {
        let a = tiny_asset();
        let mut r = Renderer::new(&a, 48000.0, 2, 256);
        r.set_room(0);
        let z = vec![0.0f32; 256];
        let mut l = vec![9.0; 256];
        let mut rr = vec![9.0; 256];
        let src = [
            Source::new(Vec3::new(0.0, 0.0, -2.0), 1.0),
            Source::new(Vec3::new(-1.0, 0.5, -1.0), 1.0),
        ];
        for _ in 0..200 {
            r.process(&Pose::from_yaw(0.3), &src, &[&z, &z], &mut l, &mut rr, 256);
        }
        assert!(l.iter().all(|x| x.is_finite() && x.abs() < 1e-3));
        assert!(rr.iter().all(|x| x.is_finite() && x.abs() < 1e-3));
    }

    #[test]
    fn earliest_reflection_arrival_matches_ear_height_geometry() {
        // Controlled render: delta HRIRs (tiny asset), room [5, 3, 6] order 1, source 2 m in
        // front at ear level. Render an impulse with reflections on vs off; the first sample
        // where the two differ is the earliest image arrival. With the ears 1.6 m above the
        // floor the earliest image is the CEILING (1.4 m overhead): path
        // sqrt(2.8^2 + 2^2) = 3.4409 m, direct 2 m -> +1.4409 m -> 201.6 samples @48k.
        // (Pre-ear-height, floor/ceiling were both 1.5 m away -> ~224.7 samples.)
        let a = tiny_asset();
        let render = |reflections: bool| -> Vec<f32> {
            let mut r = Renderer::new(&a, 48000.0, 1, 128);
            r.set_room(0);
            r.set_reflections_enabled(reflections);
            let src = [Source::new(Vec3::new(0.0, 0.0, -2.0), 1.0)];
            let silence = vec![0.0f32; 128];
            let mut impulse = vec![0.0f32; 128];
            impulse[0] = 1.0;
            let mut l = vec![0.0; 128];
            let mut rr = vec![0.0; 128];
            // settle coefficient ramps with a live-but-silent source, then fire the impulse
            for _ in 0..30 {
                r.process(&Pose::default(), &src, &[&silence], &mut l, &mut rr, 128);
            }
            let mut out = Vec::new();
            for b in 0..6 {
                let inp = if b == 0 { &impulse } else { &silence };
                r.process(&Pose::default(), &src, &[inp], &mut l, &mut rr, 128);
                for i in 0..128 {
                    out.push(l[i].abs().max(rr[i].abs()));
                }
            }
            out
        };
        let with = render(true);
        let without = render(false);
        let first = with
            .iter()
            .zip(&without)
            .position(|(a, b)| (a - b).abs() > 1e-4)
            .expect("reflections should add energy");
        let expected = (3.440_930_1f32 - 2.0) / SPEED_OF_SOUND * 48000.0; // 201.6
        assert!(
            (first as f32 - expected).abs() < 3.0,
            "earliest reflection at sample {first}, expected ~{expected}"
        );
    }

    /// Collect the first-order floor (`-y`) and ceiling (`+y`) images plus the two
    /// second-order y-axis images (my = ±2) for a source.
    fn y_images(s: Vec3, dims: [f32; 3]) -> (Vec3, Vec3, Vec3, Vec3) {
        let (mut floor, mut ceil, mut y2p, mut y2n) = (None, None, None, None);
        shoebox_images(s, dims, 2, |pos, ord, b| {
            let y_only = b[0] == 0 && b[1] == 0 && b[4] == 0 && b[5] == 0;
            if !y_only {
                return;
            }
            match (ord, b[2], b[3]) {
                (1, 0, 1) => floor = Some(pos),
                (1, 1, 0) => ceil = Some(pos),
                // my = ±2 both bounce once off each surface; sign of the mirror
                // index tells them apart via the position itself.
                (2, 1, 1) if pos.y > s.y => y2p = Some(pos),
                (2, 1, 1) if pos.y < s.y => y2n = Some(pos),
                _ => {}
            }
        });
        (floor.unwrap(), ceil.unwrap(), y2p.unwrap(), y2n.unwrap())
    }

    #[test]
    fn images_put_floor_at_ear_height_tall_room() {
        // 12 m-tall hall: floor at -1.6 m, ceiling at 10.4 m. Source at ear level.
        let dims = [18.0f32, 12.0, 28.0];
        let s = Vec3::new(1.0, 0.0, -2.0);
        let (floor, ceil, y2p, y2n) = y_images(s, dims);
        // first-order floor image: mirrored across y = -1.6 -> 2*1.6 m below the source
        assert!((floor.y - (-3.2)).abs() < 1e-4, "floor image y = {}", floor.y);
        // first-order ceiling image: mirrored across y = 10.4 -> 20.8
        assert!((ceil.y - 20.8).abs() < 1e-4, "ceiling image y = {}", ceil.y);
        // x/z untouched by y mirrors
        assert!((floor.x - s.x).abs() < 1e-6 && (floor.z - s.z).abs() < 1e-6);
        // even-m images are offset-independent: m*L + s
        assert!((y2p.y - (2.0 * 12.0 + s.y)).abs() < 1e-4);
        assert!((y2n.y - (-2.0 * 12.0 + s.y)).abs() < 1e-4);
    }

    #[test]
    fn images_valid_for_low_room_negative_offset() {
        // 3 m-tall room: room-centre offset o = 1.5 - 1.6 = -0.1 (ears just above
        // mid-height). Floor image still 2*1.6 m down; ceiling (3.0 - 1.6 = 1.4 m up)
        // image at 2*1.4 m up.
        let dims = [5.0f32, 3.0, 6.0];
        let s = Vec3::new(0.0, 0.0, -1.5);
        let (floor, ceil, _, _) = y_images(s, dims);
        assert!((floor.y - (-3.2)).abs() < 1e-4, "floor image y = {}", floor.y);
        assert!((ceil.y - 2.8).abs() < 1e-4, "ceiling image y = {}", ceil.y);
    }

    #[test]
    fn images_off_ear_level_source() {
        // Source above ear level: odd-m images are m*L - s + 2*o.
        let dims = [18.0f32, 12.0, 28.0];
        let s = Vec3::new(0.0, 1.0, -3.0);
        let (floor, ceil, _, _) = y_images(s, dims);
        // floor at -1.6: image at 2*(-1.6) - 1.0 = -4.2
        assert!((floor.y - (-4.2)).abs() < 1e-4, "floor image y = {}", floor.y);
        // ceiling at 10.4: image at 2*10.4 - 1.0 = 19.8
        assert!((ceil.y - 19.8).abs() < 1e-4, "ceiling image y = {}", ceil.y);
    }

    #[test]
    fn x_and_z_images_stay_centred() {
        // The ear-height offset applies to y ONLY: ±x/±z first-order images keep m*L - s.
        let dims = [18.0f32, 12.0, 28.0];
        let s = Vec3::new(2.0, 0.5, -3.0);
        let mut got = 0;
        shoebox_images(s, dims, 1, |pos, _ord, b| {
            if b[0] == 1 {
                assert!((pos.x - (18.0 - s.x)).abs() < 1e-4);
                got += 1;
            }
            if b[1] == 1 {
                assert!((pos.x - (-18.0 - s.x)).abs() < 1e-4);
                got += 1;
            }
            if b[4] == 1 {
                assert!((pos.z - (28.0 - s.z)).abs() < 1e-4);
                got += 1;
            }
            if b[5] == 1 {
                assert!((pos.z - (-28.0 - s.z)).abs() < 1e-4);
                got += 1;
            }
        });
        assert_eq!(got, 4);
    }
}

impl Fdn {
    fn configure_from(&mut self, dims: [f32; 3], wet: f32) {
        // reconfigure with mid/high RT60 estimated from geometry (Sabine-ish)
        let rt = (0.16 * (dims[0] * dims[1] * dims[2]) / (2.0 * (dims[0] * dims[1] + dims[1] * dims[2] + dims[0] * dims[2]) * 0.15)).clamp(0.2, 4.0);
        self.configure(rt, rt * 0.7, dims, wet);
    }
}
