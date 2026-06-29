//! Chamber binaural rendering core.
//!
//! Real-time, platform-agnostic (native + wasm32), no I/O, no threads, and no
//! allocation on the audio path (everything is allocated in [`Renderer::new`]).
//!
//! Pipeline per block: for each mono source, compute its listener-relative direction
//! from the 6DoF pose, render the **direct path** (min-phase HRIR FIR + ITD + distance)
//! and a budget of **image-source early reflections** through the same HRTF kernel, and
//! feed a mono send to a parametric **FDN late reverb**. Sum, limit, output stereo.

pub mod hrtf;
pub mod math;
pub mod reverb;
pub mod voice;

pub use math::{Quat, Vec3};

use chamber_assets::{ChamberAsset, ReverbBackend, RoomPreset};
use hrtf::HrtfDb;
use reverb::{ConvReverb, Fdn};
use voice::Voice;

pub const SPEED_OF_SOUND: f32 = 343.0;
const MAX_ITD_SAMPLES: usize = 64; // ~1.3 ms @48k
/// Global cap on simultaneously-rendered image sources (energy-ranked). Bounds reflection
/// CPU independent of source count or reflection order.
const REFLECT_BUDGET: usize = 48;
/// Image sources generated per source at order 2 (|mx|+|my|+|mz| <= 2, excluding direct).
const MAX_IMAGES_PER_SOURCE: usize = 24;

/// One candidate image source for a block (Copy so the scratch list needs no allocation).
#[derive(Clone, Copy)]
struct ImageCand {
    src: usize,
    dir: Vec3,
    dist: f32,
    ord: u32,
    amp: f32,
    energy: f32,
}

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

/// A mono point source placed in world space.
#[derive(Clone, Copy, Debug)]
pub struct Source {
    pub position: Vec3,
    /// Linear pre-gain applied to this source's input.
    pub gain: f32,
    /// Reverb send level (0..1) into the late-reverb bus.
    pub send: f32,
}
impl Source {
    pub fn new(position: Vec3, gain: f32) -> Source {
        Source {
            position,
            gain,
            send: 0.35,
        }
    }
}

struct Room {
    dims: [f32; 3],
    reflection_order: u32,
    wall_absorption: f32,
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
    reflect: Vec<Voice>, // REFLECT_BUDGET shared image-source voices
    reflections_enabled: bool,
    image_cands: Vec<ImageCand>,
    src_dist: Vec<f32>,
    silence: Vec<f32>,

    fdn: Fdn,
    conv: Option<ConvReverb>,
    rooms: Vec<Room>,
    cur_room: usize,
    room: Room,

    // smoothed head orientation
    head: Quat,
    head_pos: Vec3,
    first: bool,

    // preallocated scratch
    send_bus: Vec<f32>,
    rev_l: Vec<f32>,
    rev_r: Vec<f32>,
    hrir_l: Vec<f32>,
    hrir_r: Vec<f32>,

    master_gain: f32,
}

impl Renderer {
    /// Create a renderer from a parsed asset. `max_block` bounds the largest block
    /// passed to [`Renderer::process`]; all scratch is sized here.
    pub fn new(asset: &ChamberAsset, sample_rate: f32, max_sources: usize, max_block: usize) -> Renderer {
        let hrir_len = asset.hrir_len;
        let db = HrtfDb::from_asset(asset);
        let max_predelay = (40.0 / SPEED_OF_SOUND * sample_rate) as usize + 16; // up to ~40 m extra path

        let mut direct = Vec::with_capacity(max_sources);
        for _ in 0..max_sources {
            direct.push(Voice::new(hrir_len, MAX_ITD_SAMPLES, 1));
        }
        let mut reflect = Vec::with_capacity(REFLECT_BUDGET);
        for _ in 0..REFLECT_BUDGET {
            reflect.push(Voice::new(hrir_len, MAX_ITD_SAMPLES, max_predelay));
        }

        let mut rooms = Vec::new();
        for p in &asset.rooms {
            rooms.push(Room::from_preset(p));
        }

        let mut fdn = Fdn::new(sample_rate);
        let (room, conv) = if let Some(p) = asset.rooms.first() {
            let r = Room::from_preset(p);
            fdn.configure(p.rt60[1], p.rt60[2], mean_dim(&p.dims), p.wet);
            let c = build_conv(&r, max_block);
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
            reflections_enabled: true,
            image_cands: Vec::with_capacity(max_sources * MAX_IMAGES_PER_SOURCE),
            src_dist: vec![1.0; max_sources],
            silence: vec![0.0; max_block],
            fdn,
            conv,
            rooms,
            cur_room: 0,
            room,
            head: Quat::IDENTITY,
            head_pos: Vec3::default(),
            first: true,
            send_bus: vec![0.0; max_block],
            rev_l: vec![0.0; max_block],
            rev_r: vec![0.0; max_block],
            hrir_l: vec![0.0; hrir_len],
            hrir_r: vec![0.0; hrir_len],
            master_gain: 1.0,
        }
    }

    pub fn num_rooms(&self) -> usize {
        self.rooms.len()
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
    pub fn set_reflections_enabled(&mut self, on: bool) {
        self.reflections_enabled = on;
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
            wet: src.wet,
            backend: src.backend,
            ir_left: src.ir_left.clone(),
            ir_right: src.ir_right.clone(),
        };
        self.fdn.configure_from(self.room.dims, self.room.wet);
        self.fdn.reset();
        self.conv = build_conv(&self.room, self.max_block);
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

        for i in 0..n {
            let src = sources[i];
            let inp = &inputs[i][..frames];

            // listener-relative geometry for the direct path
            let world = src.position.sub(self.head_pos);
            let rel = inv_head.rotate(world);
            let dist = rel.len().max(1e-4);
            let dir = rel.normalized();
            self.src_dist[i] = dist;

            let dgain = src.gain * distance_atten(dist);
            let lp_a = air_lp(dist);
            let itd = self.db.interp(dir, &mut self.hrir_l, &mut self.hrir_r);

            self.direct[i].set_target(
                &self.hrir_l, &self.hrir_r, itd, dgain, lp_a, 0.0, false,
            );
            self.direct[i].process(inp, out_l, out_r, send_slice, src.send);
        }

        // deactivate unused voices (ramp to silence next block if reused)
        for i in n..self.max_sources {
            if self.direct[i].active {
                self.direct[i].set_target(
                    &self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false,
                );
                self.direct[i].active = false;
            }
        }

        // ---- image-source early reflections (order 1..2, global energy budget) ----
        if self.reflections_enabled && self.room.reflection_order >= 1 {
            let order = self.room.reflection_order;
            let refl_coeff = (1.0 - self.room.wall_absorption).max(0.0); // per bounce
            let wall_abs = self.room.wall_absorption;

            // gather candidate image sources from every source
            let head_pos = self.head_pos;
            let dims = self.room.dims;
            self.image_cands.clear();
            let cands = &mut self.image_cands;
            for i in 0..n {
                let s = sources[i].position;
                let gain = sources[i].gain;
                shoebox_images(s, dims, order, |pos, ord| {
                    let rel = inv_head.rotate(pos.sub(head_pos));
                    let idist = rel.len().max(0.05);
                    let amp = gain * refl_coeff.powi(ord as i32) * distance_atten(idist);
                    cands.push(ImageCand {
                        src: i,
                        dir: rel.normalized(),
                        dist: idist,
                        ord,
                        amp,
                        energy: amp * amp,
                    });
                });
            }
            // keep the loudest REFLECT_BUDGET (energy-ranked; bounds CPU regardless of N)
            self.image_cands
                .sort_unstable_by(|a, b| b.energy.partial_cmp(&a.energy).unwrap_or(core::cmp::Ordering::Equal));
            let k = self.image_cands.len().min(REFLECT_BUDGET);

            for slot in 0..REFLECT_BUDGET {
                if slot < k {
                    let c = self.image_cands[slot];
                    let extra = (c.dist - self.src_dist[c.src]).max(0.0);
                    let predelay = extra / SPEED_OF_SOUND * self.sr;
                    // each extra bounce adds high-frequency loss
                    let ilp = (air_lp(c.dist) * (1.0 - 0.4 * wall_abs * c.ord as f32))
                        .clamp(0.05, 1.0);
                    let iitd = self.db.interp(c.dir, &mut self.hrir_l, &mut self.hrir_r);
                    self.reflect[slot].set_target(
                        &self.hrir_l, &self.hrir_r, iitd, c.amp, ilp, predelay, false,
                    );
                    let inp = &inputs[c.src][..frames];
                    self.reflect[slot].process(inp, out_l, out_r, send_slice, 0.0);
                } else if self.reflect[slot].active {
                    self.reflect[slot].set_target(
                        &self.hrir_l, &self.hrir_r, 0.0, 0.0, 1.0, 0.0, false,
                    );
                    self.reflect[slot].process(&self.silence[..frames], out_l, out_r, send_slice, 0.0);
                    self.reflect[slot].active = false;
                }
            }
        }

        // ---- late reverb (FDN or measured-BRIR convolution, per preset) ----
        if self.room.wet > 0.0 {
            let (rl, rr) = (&mut self.rev_l[..frames], &mut self.rev_r[..frames]);
            for i in 0..frames {
                rl[i] = 0.0;
                rr[i] = 0.0;
            }
            match self.room.backend {
                ReverbBackend::Convolution if self.conv.is_some() => {
                    self.conv.as_mut().unwrap().process(send_slice, rl, rr);
                }
                _ => {
                    self.fdn.process(send_slice, rl, rr);
                }
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

fn mean_dim(d: &[f32; 3]) -> f32 {
    (d[0] + d[1] + d[2]) / 3.0
}

/// Build a convolution reverb for a room if it uses a BRIR; otherwise None.
fn build_conv(room: &Room, max_block: usize) -> Option<ConvReverb> {
    if room.backend == ReverbBackend::Convolution && !room.ir_left.is_empty() {
        Some(ConvReverb::new(
            128,
            &room.ir_left,
            &room.ir_right,
            room.wet,
            max_block,
        ))
    } else {
        None
    }
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

/// Enumerate shoebox image sources up to `order` for a room centred at the origin with
/// walls at ±dim/2. For a 1-D room the image of source `s` is `m*L + (-1)^m * s`; the 3-D
/// images are the product, with reflection order `|mx|+|my|+|mz|`. Calls `push(pos, order)`
/// for each image (excluding the direct path, order 0).
fn shoebox_images(s: Vec3, dims: [f32; 3], order: u32, mut push: impl FnMut(Vec3, u32)) {
    let o = order as i32;
    let (lx, ly, lz) = (dims[0], dims[1], dims[2]);
    let axis = |m: i32, l: f32, c: f32| m as f32 * l + if m & 1 == 0 { c } else { -c };
    for mx in -o..=o {
        for my in -o..=o {
            for mz in -o..=o {
                let ord = mx.abs() + my.abs() + mz.abs();
                if ord == 0 || ord > o {
                    continue;
                }
                push(
                    Vec3::new(axis(mx, lx, s.x), axis(my, ly, s.y), axis(mz, lz, s.z)),
                    ord as u32,
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chamber_assets::{AssetBuilder, ReverbBackend, RoomPreset};

    // A tiny 2-direction asset (front + right) is enough to exercise the pipeline.
    fn tiny_asset() -> ChamberAsset {
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
            reflection_order: 1,
            wet: 0.25,
            backend: ReverbBackend::Fdn,
            ir_left: vec![],
            ir_right: vec![],
        });
        let bytes = b.to_bytes();
        ChamberAsset::parse(&bytes).unwrap()
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
}

impl Fdn {
    fn configure_from(&mut self, dims: [f32; 3], wet: f32) {
        // reconfigure with mid/high RT60 estimated from geometry (Sabine-ish via size)
        let size = mean_dim(&dims);
        let rt = (0.16 * (dims[0] * dims[1] * dims[2]) / (2.0 * (dims[0] * dims[1] + dims[1] * dims[2] + dims[0] * dims[2]) * 0.15)).clamp(0.2, 4.0);
        self.configure(rt, rt * 0.7, size, wet);
    }
}
