//! The `.antiphon` asset format: a compact, little-endian container holding a spherical
//! HRTF grid (minimum-phase HRIR pairs + per-direction ITD) plus a small set of
//! parametric room presets.
//!
//! The runtime ([`AntiphonAsset::parse`]) has **no external dependencies** and does no
//! FFT / HDF5 / SOFA work — everything heavy happens once, offline, in `antiphon-bake`,
//! which builds an [`AssetBuilder`] (behind the `write` feature). This is what keeps the
//! WASM runtime lean.
//!
//! Layout (all multi-byte values little-endian):
//! ```text
//! magic   "CHMB"                              4 bytes
//! version u32                                 = FORMAT_VERSION
//! sample_rate f32
//! hrir_len u32   (taps per ear, e.g. 128)
//! num_dirs u32
//! num_rooms u32
//! flags u32                                   (reserved)
//! --- directions: num_dirs * (az f32, el f32, ux f32, uy f32, uz f32, itd f32)
//! --- hrir: num_dirs * (left[hrir_len] f32, right[hrir_len] f32)   (minimum-phase)
//! --- rooms: num_rooms * RoomPreset (see below)
//! ```

#![cfg_attr(not(feature = "write"), no_std)]
extern crate alloc;

use alloc::string::String;
use alloc::vec::Vec;

pub const MAGIC: [u8; 4] = *b"CHMB";
/// v3 adds per-surface 3-band absorption to each room. v2 assets still parse (the broadband
/// `wall_absorption` is replicated across all surfaces/bands).
pub const FORMAT_VERSION: u32 = 3;

/// Reverb backend a room preset asks the engine to use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum ReverbBackend {
    /// Parametric feedback-delay-network late reverb (no measured IR needed).
    Fdn = 0,
    /// Convolution against a measured/synthesized stereo late-BRIR (Tier 1).
    Convolution = 1,
}

impl ReverbBackend {
    fn from_u32(v: u32) -> Self {
        match v {
            1 => ReverbBackend::Convolution,
            _ => ReverbBackend::Fdn,
        }
    }
}

/// One measured direction and its associated minimum-phase HRIR pair + ITD.
#[derive(Clone, Debug)]
pub struct Direction {
    /// Azimuth in radians. 0 = front, +pi/2 = left, -pi/2 = right (see docs/conventions.md).
    pub az: f32,
    /// Elevation in radians. 0 = ear level, +pi/2 = straight up.
    pub el: f32,
    /// Unit vector for this direction (precomputed for fast nearest-neighbour search).
    pub unit: [f32; 3],
    /// Interaural time difference in fractional samples. Positive => source toward the
    /// left, so the **right** ear is delayed by `itd`; negative delays the left ear.
    pub itd: f32,
}

/// A parametric room. The engine derives an FDN (or selects a convolution IR) from this.
#[derive(Clone, Debug)]
pub struct RoomPreset {
    pub name: String,
    /// Shoebox dimensions in metres (w, h, d). Used by the image-source early reflections.
    pub dims: [f32; 3],
    /// Target RT60 (seconds) in low / mid / high bands.
    pub rt60: [f32; 3],
    /// Broadband wall absorption coefficient 0..1 (image-source attenuation per bounce).
    /// Retained for back-compat / as the fallback when per-surface data is absent.
    pub wall_absorption: f32,
    /// Per-surface 3-band absorption coefficients (0..1). Surfaces in the order
    /// `[+x, -x, +y(ceiling), -y(floor), +z, -z]`; bands `[low, mid, high]`. Real rooms absorb
    /// high frequencies more, and the floor (carpet/people) more than the walls — this is what
    /// lets the image-source reflections carry a believable, direction-dependent spectrum.
    pub surface_abs: [[f32; 3]; 6],
    /// Highest image-source reflection order to compute (0 disables early reflections).
    pub reflection_order: u32,
    /// Wet gain applied to the reverb bus for this preset.
    pub wet: f32,
    pub backend: ReverbBackend,
    /// Stereo late-BRIR for the `Convolution` backend (empty for `Fdn`). `ir_left` and
    /// `ir_right` have equal length; the engine convolves the mono send against both.
    pub ir_left: Vec<f32>,
    pub ir_right: Vec<f32>,
}

/// Parsed, owned view of a `.antiphon` asset.
#[derive(Clone, Debug)]
pub struct AntiphonAsset {
    pub sample_rate: f32,
    pub hrir_len: usize,
    pub directions: Vec<Direction>,
    /// Flattened left HRIRs: `directions.len() * hrir_len`.
    pub hrir_left: Vec<f32>,
    /// Flattened right HRIRs: `directions.len() * hrir_len`.
    pub hrir_right: Vec<f32>,
    pub rooms: Vec<RoomPreset>,
}

#[derive(Debug)]
pub enum ParseError {
    TooShort,
    BadMagic,
    BadVersion(u32),
    Truncated(&'static str),
}

struct Cursor<'a> {
    b: &'a [u8],
    p: usize,
}
impl<'a> Cursor<'a> {
    fn new(b: &'a [u8]) -> Self {
        Cursor { b, p: 0 }
    }
    fn u32(&mut self) -> Result<u32, ParseError> {
        let s = self.take(4, "u32")?;
        Ok(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
    fn f32(&mut self) -> Result<f32, ParseError> {
        Ok(f32::from_bits(self.u32()?))
    }
    fn take(&mut self, n: usize, what: &'static str) -> Result<&'a [u8], ParseError> {
        if self.p + n > self.b.len() {
            return Err(ParseError::Truncated(what));
        }
        let s = &self.b[self.p..self.p + n];
        self.p += n;
        Ok(s)
    }
}

impl AntiphonAsset {
    /// Parse a `.antiphon` blob. Pure arithmetic + allocation; no I/O, no FFT.
    pub fn parse(bytes: &[u8]) -> Result<AntiphonAsset, ParseError> {
        if bytes.len() < 28 {
            return Err(ParseError::TooShort);
        }
        let mut c = Cursor::new(bytes);
        let magic = c.take(4, "magic")?;
        if magic != MAGIC {
            return Err(ParseError::BadMagic);
        }
        let version = c.u32()?;
        if version != 2 && version != 3 {
            return Err(ParseError::BadVersion(version));
        }
        let sample_rate = c.f32()?;
        let hrir_len = c.u32()? as usize;
        let num_dirs = c.u32()? as usize;
        let num_rooms = c.u32()? as usize;
        let _flags = c.u32()?;

        let mut directions = Vec::with_capacity(num_dirs);
        for _ in 0..num_dirs {
            let az = c.f32()?;
            let el = c.f32()?;
            let ux = c.f32()?;
            let uy = c.f32()?;
            let uz = c.f32()?;
            let itd = c.f32()?;
            directions.push(Direction {
                az,
                el,
                unit: [ux, uy, uz],
                itd,
            });
        }

        let n = num_dirs * hrir_len;
        let mut hrir_left = Vec::with_capacity(n);
        let mut hrir_right = Vec::with_capacity(n);
        for _ in 0..n {
            hrir_left.push(c.f32()?);
        }
        for _ in 0..n {
            hrir_right.push(c.f32()?);
        }

        let mut rooms = Vec::with_capacity(num_rooms);
        for _ in 0..num_rooms {
            // name: 16 fixed bytes, nul-padded
            let nb = c.take(16, "room name")?;
            let end = nb.iter().position(|&x| x == 0).unwrap_or(16);
            let name = core::str::from_utf8(&nb[..end])
                .unwrap_or("room")
                .into();
            let dims = [c.f32()?, c.f32()?, c.f32()?];
            let rt60 = [c.f32()?, c.f32()?, c.f32()?];
            let wall_absorption = c.f32()?;
            // v3: per-surface 3-band absorption; v2: replicate the broadband scalar.
            let mut surface_abs = [[wall_absorption; 3]; 6];
            if version >= 3 {
                for s in 0..6 {
                    for b in 0..3 {
                        surface_abs[s][b] = c.f32()?;
                    }
                }
            }
            let reflection_order = c.u32()?;
            let wet = c.f32()?;
            let backend = ReverbBackend::from_u32(c.u32()?);
            let ir_len = c.u32()? as usize;
            let mut ir_left = Vec::with_capacity(ir_len);
            for _ in 0..ir_len {
                ir_left.push(c.f32()?);
            }
            let mut ir_right = Vec::with_capacity(ir_len);
            for _ in 0..ir_len {
                ir_right.push(c.f32()?);
            }
            rooms.push(RoomPreset {
                name,
                dims,
                rt60,
                wall_absorption,
                surface_abs,
                reflection_order,
                wet,
                backend,
                ir_left,
                ir_right,
            });
        }

        Ok(AntiphonAsset {
            sample_rate,
            hrir_len,
            directions,
            hrir_left,
            hrir_right,
            rooms,
        })
    }

    #[inline]
    pub fn hrir_left_of(&self, dir: usize) -> &[f32] {
        &self.hrir_left[dir * self.hrir_len..(dir + 1) * self.hrir_len]
    }
    #[inline]
    pub fn hrir_right_of(&self, dir: usize) -> &[f32] {
        &self.hrir_right[dir * self.hrir_len..(dir + 1) * self.hrir_len]
    }
}

// ---------------------------------------------------------------------------
// Writer (offline baker only)
// ---------------------------------------------------------------------------

#[cfg(feature = "write")]
mod build {
    use super::*;

    /// Accumulates an asset and serializes it to the `.antiphon` byte layout.
    pub struct AssetBuilder {
        pub sample_rate: f32,
        pub hrir_len: usize,
        pub directions: Vec<Direction>,
        pub hrir_left: Vec<f32>,
        pub hrir_right: Vec<f32>,
        pub rooms: Vec<RoomPreset>,
    }

    impl AssetBuilder {
        pub fn new(sample_rate: f32, hrir_len: usize) -> Self {
            AssetBuilder {
                sample_rate,
                hrir_len,
                directions: Vec::new(),
                hrir_left: Vec::new(),
                hrir_right: Vec::new(),
                rooms: Vec::new(),
            }
        }

        /// Append a measured direction. `left`/`right` must each be `hrir_len` long.
        pub fn push_direction(&mut self, az: f32, el: f32, itd: f32, left: &[f32], right: &[f32]) {
            assert_eq!(left.len(), self.hrir_len);
            assert_eq!(right.len(), self.hrir_len);
            let (ce, se) = (el.cos(), el.sin());
            let (ca, sa) = (az.cos(), az.sin());
            // Convention: +x right, +y up, +z back (front = -z). az measured toward +left.
            let unit = [-ce * sa, se, -ce * ca];
            self.directions.push(Direction { az, el, unit, itd });
            self.hrir_left.extend_from_slice(left);
            self.hrir_right.extend_from_slice(right);
        }

        pub fn push_room(&mut self, room: RoomPreset) {
            self.rooms.push(room);
        }

        pub fn to_bytes(&self) -> Vec<u8> {
            let mut o = Vec::new();
            o.extend_from_slice(&MAGIC);
            o.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
            o.extend_from_slice(&self.sample_rate.to_le_bytes());
            o.extend_from_slice(&(self.hrir_len as u32).to_le_bytes());
            o.extend_from_slice(&(self.directions.len() as u32).to_le_bytes());
            o.extend_from_slice(&(self.rooms.len() as u32).to_le_bytes());
            o.extend_from_slice(&0u32.to_le_bytes()); // flags

            for d in &self.directions {
                for v in [d.az, d.el, d.unit[0], d.unit[1], d.unit[2], d.itd] {
                    o.extend_from_slice(&v.to_le_bytes());
                }
            }
            for v in &self.hrir_left {
                o.extend_from_slice(&v.to_le_bytes());
            }
            for v in &self.hrir_right {
                o.extend_from_slice(&v.to_le_bytes());
            }
            for r in &self.rooms {
                let mut name = [0u8; 16];
                let nb = r.name.as_bytes();
                let k = nb.len().min(16);
                name[..k].copy_from_slice(&nb[..k]);
                o.extend_from_slice(&name);
                for v in [
                    r.dims[0], r.dims[1], r.dims[2], r.rt60[0], r.rt60[1], r.rt60[2],
                    r.wall_absorption,
                ] {
                    o.extend_from_slice(&v.to_le_bytes());
                }
                // v3: per-surface 3-band absorption (6 surfaces x 3 bands)
                for s in &r.surface_abs {
                    for v in s {
                        o.extend_from_slice(&v.to_le_bytes());
                    }
                }
                o.extend_from_slice(&r.reflection_order.to_le_bytes());
                o.extend_from_slice(&r.wet.to_le_bytes());
                o.extend_from_slice(&(r.backend as u32).to_le_bytes());
                debug_assert_eq!(r.ir_left.len(), r.ir_right.len());
                o.extend_from_slice(&(r.ir_left.len() as u32).to_le_bytes());
                for v in &r.ir_left {
                    o.extend_from_slice(&v.to_le_bytes());
                }
                for v in &r.ir_right {
                    o.extend_from_slice(&v.to_le_bytes());
                }
            }
            o
        }
    }
}

#[cfg(feature = "write")]
pub use build::AssetBuilder;

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "write")]
    #[test]
    fn roundtrip() {
        let mut b = AssetBuilder::new(48000.0, 4);
        b.push_direction(0.0, 0.0, 0.0, &[1.0, 0.0, 0.0, 0.0], &[1.0, 0.0, 0.0, 0.0]);
        b.push_direction(1.0, 0.2, 3.5, &[0.5, 0.5, 0.0, 0.0], &[0.0, 0.5, 0.5, 0.0]);
        b.push_room(RoomPreset {
            name: "hall".into(),
            dims: [10.0, 6.0, 14.0],
            rt60: [2.0, 1.8, 1.2],
            wall_absorption: 0.08,
            surface_abs: [[0.05, 0.08, 0.16]; 6],
            reflection_order: 2,
            wet: 0.3,
            backend: ReverbBackend::Fdn,
            ir_left: vec![],
            ir_right: vec![],
        });
        b.push_room(RoomPreset {
            name: "plate".into(),
            dims: [4.0, 3.0, 5.0],
            rt60: [1.0, 0.9, 0.6],
            wall_absorption: 0.1,
            surface_abs: [[0.06, 0.1, 0.2]; 6],
            reflection_order: 0,
            wet: 0.3,
            backend: ReverbBackend::Convolution,
            ir_left: vec![1.0, 0.5, 0.25],
            ir_right: vec![0.9, 0.4, 0.2],
        });
        let bytes = b.to_bytes();
        let a = AntiphonAsset::parse(&bytes).unwrap();
        assert_eq!(a.sample_rate, 48000.0);
        assert_eq!(a.hrir_len, 4);
        assert_eq!(a.directions.len(), 2);
        assert_eq!(a.rooms.len(), 2);
        assert_eq!(a.rooms[0].name, "hall");
        assert!((a.directions[1].itd - 3.5).abs() < 1e-6);
        assert_eq!(a.hrir_right_of(1), &[0.0, 0.5, 0.5, 0.0]);
        assert_eq!(a.rooms[1].backend, ReverbBackend::Convolution);
        assert_eq!(a.rooms[1].ir_left, vec![1.0, 0.5, 0.25]);
        assert_eq!(a.rooms[1].ir_right, vec![0.9, 0.4, 0.2]);
    }
}
