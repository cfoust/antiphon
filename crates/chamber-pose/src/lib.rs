//! Head pose (6DoF) from 2D facial landmarks by solving PnP (Perspective-n-Point).
//!
//! This is the same geometry MediaPipe computes for its face-transform matrix on the web —
//! a fit of a canonical 3D face model to detected 2D landmarks — but computed natively from
//! whatever landmarks the host has (e.g. Apple Vision). Given image points + camera
//! intrinsics, an iterative Levenberg–Marquardt solve recovers the head rotation and metric
//! translation in the camera frame.
//!
//! Camera convention (OpenCV-style): +x right, +y down, +z forward (into the scene). A pixel
//! is `u = f·Xc.x/Xc.z + cx`, `v = f·Xc.y/Xc.z + cy`.

type V3 = [f64; 3];
type M3 = [[f64; 3]; 3];

/// Canonical face model points (metres), in the **camera's view convention** so that a head
/// facing the camera solves to ~identity (no 180° flip): +x = camera-right, +y = camera-down,
/// +z = away from camera (toward the back of the head). The subject's LEFT eye is therefore
/// at +x (it appears on the right of a non-mirrored image). Order is fixed; the host supplies
/// matching image points in the same order:
/// [nose, chin, subject-left-eye, subject-right-eye, subject-left-mouth, subject-right-mouth].
pub const MODEL: [V3; 6] = [
    [0.0, 0.0, 0.0],            // 0 nose tip (frontmost)
    [0.0, 0.075, 0.02],         // 1 chin (down, slightly back)
    [0.046, -0.034, 0.03],      // 2 subject-left eye (camera-right, up, back)
    [-0.046, -0.034, 0.03],     // 3 subject-right eye (camera-left)
    [0.026, 0.043, 0.02],       // 4 subject-left mouth corner
    [-0.026, 0.043, 0.02],      // 5 subject-right mouth corner
];

/// Recovered head pose.
#[derive(Clone, Copy, Debug)]
pub struct HeadPose {
    /// model->camera rotation as a quaternion (w, x, y, z).
    pub quat: [f32; 4],
    /// head (nose-tip) position in the camera frame, metres (+x right, +y down, +z forward).
    pub pos: [f32; 3],
    pub yaw_deg: f32,
    pub pitch_deg: f32,
    pub roll_deg: f32,
    /// mean reprojection error in pixels (quality indicator).
    pub reproj_err: f32,
}

// ---- small linear algebra (no deps) ---------------------------------------

fn skew(w: V3) -> M3 {
    [[0.0, -w[2], w[1]], [w[2], 0.0, -w[0]], [-w[1], w[0], 0.0]]
}
fn mat_mul(a: M3, b: M3) -> M3 {
    let mut r = [[0.0; 3]; 3];
    for i in 0..3 {
        for j in 0..3 {
            r[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
        }
    }
    r
}
fn mat_vec(a: M3, v: V3) -> V3 {
    [
        a[0][0] * v[0] + a[0][1] * v[1] + a[0][2] * v[2],
        a[1][0] * v[0] + a[1][1] * v[1] + a[1][2] * v[2],
        a[2][0] * v[0] + a[2][1] * v[1] + a[2][2] * v[2],
    ]
}
fn identity() -> M3 {
    [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
}

/// Rodrigues: rotation matrix for axis-angle `w`.
fn rodrigues(w: V3) -> M3 {
    let theta = (w[0] * w[0] + w[1] * w[1] + w[2] * w[2]).sqrt();
    let k = skew(w);
    if theta < 1e-9 {
        // I + K (first order) is plenty for tiny increments
        let mut r = identity();
        for i in 0..3 {
            for j in 0..3 {
                r[i][j] += k[i][j];
            }
        }
        return r;
    }
    let kn = skew([w[0] / theta, w[1] / theta, w[2] / theta]);
    let k2 = mat_mul(kn, kn);
    let s = theta.sin();
    let c = 1.0 - theta.cos();
    let mut r = identity();
    for i in 0..3 {
        for j in 0..3 {
            r[i][j] += s * kn[i][j] + c * k2[i][j];
        }
    }
    r
}

/// Solve a 6x6 linear system `A x = b` (Gaussian elimination, partial pivot).
fn solve6(mut a: [[f64; 6]; 6], mut b: [f64; 6]) -> Option<[f64; 6]> {
    for col in 0..6 {
        // pivot
        let mut piv = col;
        for r in col + 1..6 {
            if a[r][col].abs() > a[piv][col].abs() {
                piv = r;
            }
        }
        if a[piv][col].abs() < 1e-12 {
            return None;
        }
        a.swap(col, piv);
        b.swap(col, piv);
        let d = a[col][col];
        for r in 0..6 {
            if r == col {
                continue;
            }
            let f = a[r][col] / d;
            for c in col..6 {
                a[r][c] -= f * a[col][c];
            }
            b[r] -= f * b[col];
        }
    }
    let mut x = [0.0; 6];
    for i in 0..6 {
        x[i] = b[i] / a[i][i];
    }
    Some(x)
}

fn mat_to_quat(r: M3) -> [f32; 4] {
    let tr = r[0][0] + r[1][1] + r[2][2];
    let (w, x, y, z);
    if tr > 0.0 {
        let s = (tr + 1.0).sqrt() * 2.0;
        w = 0.25 * s;
        x = (r[2][1] - r[1][2]) / s;
        y = (r[0][2] - r[2][0]) / s;
        z = (r[1][0] - r[0][1]) / s;
    } else if r[0][0] > r[1][1] && r[0][0] > r[2][2] {
        let s = (1.0 + r[0][0] - r[1][1] - r[2][2]).sqrt() * 2.0;
        w = (r[2][1] - r[1][2]) / s;
        x = 0.25 * s;
        y = (r[0][1] + r[1][0]) / s;
        z = (r[0][2] + r[2][0]) / s;
    } else if r[1][1] > r[2][2] {
        let s = (1.0 + r[1][1] - r[0][0] - r[2][2]).sqrt() * 2.0;
        w = (r[0][2] - r[2][0]) / s;
        x = (r[0][1] + r[1][0]) / s;
        y = 0.25 * s;
        z = (r[1][2] + r[2][1]) / s;
    } else {
        let s = (1.0 + r[2][2] - r[0][0] - r[1][1]).sqrt() * 2.0;
        w = (r[1][0] - r[0][1]) / s;
        x = (r[0][2] + r[2][0]) / s;
        y = (r[1][2] + r[2][1]) / s;
        z = 0.25 * s;
    }
    [w as f32, x as f32, y as f32, z as f32]
}

/// Solve head pose from image points (pixels, same order as [`MODEL`]) and intrinsics.
/// `f` = focal length in pixels (≈ image width when the true FOV is unknown).
pub fn solve(image_pts: &[[f64; 2]], f: f64, cx: f64, cy: f64) -> Option<HeadPose> {
    let n = image_pts.len().min(MODEL.len());
    if n < 4 {
        return None;
    }
    let mut r = identity();
    let mut t: V3 = [0.0, 0.0, 0.6]; // head ~0.6 m in front of the camera

    let mut lambda = 1e-3;
    let mut last_cost = f64::INFINITY;

    for _ in 0..30 {
        let mut h = [[0.0f64; 6]; 6];
        let mut g = [0.0f64; 6];
        let mut cost = 0.0;
        for i in 0..n {
            let x = MODEL[i];
            let rx = mat_vec(r, x);
            let xc = [rx[0] + t[0], rx[1] + t[1], rx[2] + t[2]];
            if xc[2] < 1e-4 {
                continue;
            }
            let inv_z = 1.0 / xc[2];
            let up = f * xc[0] * inv_z + cx;
            let vp = f * xc[1] * inv_z + cy;
            let ru = up - image_pts[i][0];
            let rv = vp - image_pts[i][1];
            cost += ru * ru + rv * rv;

            // d(proj)/d(Xc) : 2x3
            let jp = [
                [f * inv_z, 0.0, -f * xc[0] * inv_z * inv_z],
                [0.0, f * inv_z, -f * xc[1] * inv_z * inv_z],
            ];
            // d(Xc)/d(omega) = -skew(R*X) (left perturbation R<-exp(dw)R), d(Xc)/d(t) = I
            let ns = skew(rx); // skew(R*X); we want -skew, fold sign below
            // J (2x6): cols 0..3 = jp * (-ns), cols 3..6 = jp
            let mut jrow = [[0.0f64; 6]; 2];
            for a in 0..2 {
                // rotation part
                for c in 0..3 {
                    let mut v = 0.0;
                    for k in 0..3 {
                        v += jp[a][k] * (-ns[k][c]);
                    }
                    jrow[a][c] = v;
                }
                // translation part
                for c in 0..3 {
                    jrow[a][3 + c] = jp[a][c];
                }
            }
            let res = [ru, rv];
            for a in 0..2 {
                for p in 0..6 {
                    g[p] += jrow[a][p] * res[a];
                    for q in 0..6 {
                        h[p][q] += jrow[a][p] * jrow[a][q];
                    }
                }
            }
        }

        // LM damping on the diagonal
        let mut hd = h;
        for d in 0..6 {
            hd[d][d] += lambda * h[d][d].max(1e-9);
        }
        let neg_g = [-g[0], -g[1], -g[2], -g[3], -g[4], -g[5]];
        let delta = match solve6(hd, neg_g) {
            Some(d) => d,
            None => break,
        };
        // apply
        let r_new = mat_mul(rodrigues([delta[0], delta[1], delta[2]]), r);
        let t_new = [t[0] + delta[3], t[1] + delta[4], t[2] + delta[5]];
        r = r_new;
        t = t_new;

        if (last_cost - cost).abs() < 1e-9 {
            break;
        }
        if cost < last_cost {
            lambda = (lambda * 0.5).max(1e-6);
        } else {
            lambda = (lambda * 2.0).min(1e3);
        }
        last_cost = cost;
    }

    // reprojection error
    let mut err = 0.0f64;
    let mut cnt = 0.0f64;
    for i in 0..n {
        let xc = {
            let rx = mat_vec(r, MODEL[i]);
            [rx[0] + t[0], rx[1] + t[1], rx[2] + t[2]]
        };
        if xc[2] < 1e-4 {
            continue;
        }
        let up = f * xc[0] / xc[2] + cx;
        let vp = f * xc[1] / xc[2] + cy;
        err += ((up - image_pts[i][0]).powi(2) + (vp - image_pts[i][1]).powi(2)).sqrt();
        cnt += 1.0;
    }

    // Euler (yaw about y, pitch about x, roll about z) from R
    let yaw = r[0][2].atan2(r[2][2]).to_degrees();
    let pitch = (-r[1][2]).asin().clamp(-1.5708, 1.5708).to_degrees();
    let roll = r[1][0].atan2(r[1][1]).to_degrees();

    Some(HeadPose {
        quat: mat_to_quat(r),
        pos: [t[0] as f32, t[1] as f32, t[2] as f32],
        yaw_deg: yaw as f32,
        pitch_deg: pitch as f32,
        roll_deg: roll as f32,
        reproj_err: (err / cnt.max(1.0)) as f32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(r: M3, t: V3, f: f64, cx: f64, cy: f64) -> Vec<[f64; 2]> {
        MODEL
            .iter()
            .map(|x| {
                let rx = mat_vec(r, *x);
                let xc = [rx[0] + t[0], rx[1] + t[1], rx[2] + t[2]];
                [f * xc[0] / xc[2] + cx, f * xc[1] / xc[2] + cy]
            })
            .collect()
    }

    #[test]
    fn recovers_known_pose() {
        let (f, cx, cy) = (640.0, 320.0, 240.0);
        // a known head pose: yaw ~20°, slight pitch, offset + 0.55 m away
        let r = rodrigues([0.10, 0.35, -0.05]);
        let t = [0.04, -0.02, 0.55];
        let pts = project(r, t, f, cx, cy);

        let p = solve(&pts, f, cx, cy).expect("solve");
        assert!(p.reproj_err < 0.5, "reproj_err {}", p.reproj_err);
        assert!((p.pos[0] as f64 - t[0]).abs() < 0.01, "x {:?}", p.pos);
        assert!((p.pos[1] as f64 - t[1]).abs() < 0.01, "y {:?}", p.pos);
        assert!((p.pos[2] as f64 - t[2]).abs() < 0.02, "z {:?}", p.pos);
    }

    #[test]
    fn recovers_translation_sweep() {
        let (f, cx, cy) = (700.0, 360.0, 240.0);
        for dx in [-0.1, 0.0, 0.12] {
            let r = rodrigues([0.0, 0.0, 0.0]);
            let t = [dx, 0.03, 0.6];
            let pts = project(r, t, f, cx, cy);
            let p = solve(&pts, f, cx, cy).unwrap();
            assert!((p.pos[0] as f64 - dx).abs() < 0.01, "dx {} -> {:?}", dx, p.pos);
        }
    }
}
