//! Minimal vector / quaternion math for pose transforms. No external deps.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Vec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vec3 {
    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Vec3 { x, y, z }
    }
    pub fn sub(self, o: Vec3) -> Vec3 {
        Vec3::new(self.x - o.x, self.y - o.y, self.z - o.z)
    }
    pub fn dot(self, o: Vec3) -> f32 {
        self.x * o.x + self.y * o.y + self.z * o.z
    }
    pub fn len(self) -> f32 {
        self.dot(self).sqrt()
    }
    pub fn normalized(self) -> Vec3 {
        let l = self.len();
        if l > 1e-9 {
            Vec3::new(self.x / l, self.y / l, self.z / l)
        } else {
            Vec3::new(0.0, 0.0, -1.0)
        }
    }
}

/// Unit quaternion (w, x, y, z) describing the listener's head orientation.
#[derive(Clone, Copy, Debug)]
pub struct Quat {
    pub w: f32,
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Default for Quat {
    fn default() -> Self {
        Quat::IDENTITY
    }
}

impl Quat {
    pub const IDENTITY: Quat = Quat {
        w: 1.0,
        x: 0.0,
        y: 0.0,
        z: 0.0,
    };

    pub fn from_yaw(yaw: f32) -> Quat {
        // Rotation about +y (up). Yaw>0 turns head toward +left.
        let h = 0.5 * yaw;
        Quat {
            w: h.cos(),
            x: 0.0,
            y: h.sin(),
            z: 0.0,
        }
    }

    /// Yaw (about y), pitch (about x), roll (about z) intrinsic, applied y*x*z.
    pub fn from_ypr(yaw: f32, pitch: f32, roll: f32) -> Quat {
        let qy = Quat::from_axis(0.0, 1.0, 0.0, yaw);
        let qx = Quat::from_axis(1.0, 0.0, 0.0, pitch);
        let qz = Quat::from_axis(0.0, 0.0, 1.0, roll);
        qy.mul(qx).mul(qz).normalized()
    }

    fn from_axis(ax: f32, ay: f32, az: f32, ang: f32) -> Quat {
        let h = 0.5 * ang;
        let s = h.sin();
        Quat {
            w: h.cos(),
            x: ax * s,
            y: ay * s,
            z: az * s,
        }
    }

    pub fn mul(self, o: Quat) -> Quat {
        Quat {
            w: self.w * o.w - self.x * o.x - self.y * o.y - self.z * o.z,
            x: self.w * o.x + self.x * o.w + self.y * o.z - self.z * o.y,
            y: self.w * o.y - self.x * o.z + self.y * o.w + self.z * o.x,
            z: self.w * o.z + self.x * o.y - self.y * o.x + self.z * o.w,
        }
    }

    pub fn normalized(self) -> Quat {
        let n = (self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z).sqrt();
        if n > 1e-9 {
            Quat {
                w: self.w / n,
                x: self.x / n,
                y: self.y / n,
                z: self.z / n,
            }
        } else {
            Quat::IDENTITY
        }
    }

    pub fn conjugate(self) -> Quat {
        Quat {
            w: self.w,
            x: -self.x,
            y: -self.y,
            z: -self.z,
        }
    }

    /// Rotate a vector by this quaternion.
    pub fn rotate(self, v: Vec3) -> Vec3 {
        // t = 2 * cross(q.xyz, v); v' = v + q.w*t + cross(q.xyz, t)
        let qx = self.x;
        let qy = self.y;
        let qz = self.z;
        let tx = 2.0 * (qy * v.z - qz * v.y);
        let ty = 2.0 * (qz * v.x - qx * v.z);
        let tz = 2.0 * (qx * v.y - qy * v.x);
        Vec3::new(
            v.x + self.w * tx + (qy * tz - qz * ty),
            v.y + self.w * ty + (qz * tx - qx * tz),
            v.z + self.w * tz + (qx * ty - qy * tx),
        )
    }

    /// Spherical-ish normalized lerp between orientations (cheap, click-free for small steps).
    pub fn nlerp(self, o: Quat, t: f32) -> Quat {
        // pick shorter arc
        let d = self.w * o.w + self.x * o.x + self.y * o.y + self.z * o.z;
        let s = if d < 0.0 { -1.0 } else { 1.0 };
        Quat {
            w: self.w + t * (s * o.w - self.w),
            x: self.x + t * (s * o.x - self.x),
            y: self.y + t * (s * o.y - self.y),
            z: self.z + t * (s * o.z - self.z),
        }
        .normalized()
    }
}
