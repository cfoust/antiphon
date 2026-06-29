//! Runtime HRTF database: interpolates a minimum-phase HRIR pair + ITD for any
//! listener-relative direction from the discrete grid stored in the asset.
//!
//! Interpolation is inverse-angular-distance weighting over the K nearest measured
//! directions (K=3). Because the stored HRIRs are minimum-phase, their taps can be
//! blended linearly without comb-filtering; the ITD is blended as a scalar and applied
//! separately as a fractional delay in [`crate::voice`].

use crate::math::Vec3;
use chamber_assets::ChamberAsset;

const K: usize = 3;

pub struct HrtfDb {
    pub hrir_len: usize,
    units: Vec<Vec3>,
    itd: Vec<f32>,
    left: Vec<f32>,  // num_dirs * hrir_len
    right: Vec<f32>, // num_dirs * hrir_len
}

impl HrtfDb {
    pub fn from_asset(a: &ChamberAsset) -> HrtfDb {
        let units = a
            .directions
            .iter()
            .map(|d| Vec3::new(d.unit[0], d.unit[1], d.unit[2]))
            .collect();
        let itd = a.directions.iter().map(|d| d.itd).collect();
        HrtfDb {
            hrir_len: a.hrir_len,
            units,
            itd,
            left: a.hrir_left.clone(),
            right: a.hrir_right.clone(),
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
