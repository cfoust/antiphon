//! C ABI over `chamber-dsp` for native hosts (Swift / CoreAudio).
//!
//! The hot call ([`chamber_renderer_process`]) does no I/O, no locking, and no syscalls.
//! The asset bytes are copied/parsed once in [`chamber_renderer_create`]; everything the
//! renderer needs is preallocated there. `panic = "abort"` (set in the workspace release
//! profile) ensures we never unwind across the FFI boundary.
//!
//! See `native/CChamber/chamber.h` for the matching C declarations.

use chamber_assets::ChamberAsset;
use chamber_dsp::{Pose, Quat, Renderer, Source, Vec3};
use std::os::raw::c_void;

/// Solve 6DoF head pose from facial landmarks (PnP) — native 6DoF without MediaPipe.
///
/// `image_pts` is `2*n` floats `(x, y)` in PIXELS, in `chamber_pose::MODEL` order
/// (nose tip, chin, left-eye outer, right-eye outer, left-mouth, right-mouth). `focal`
/// is in pixels (≈ image width if unknown). Writes yaw/pitch/roll (degrees) to `out_ypr[3]`,
/// camera-frame position (metres, +x right/+y down/+z forward) to `out_pos[3]`, and the mean
/// reprojection error (px) to `out_err[1]`. Returns 1 on success, 0 on failure.
///
/// # Safety: pointers must be valid for the indicated lengths.
#[no_mangle]
pub unsafe extern "C" fn chamber_solve_head_pose(
    image_pts: *const f32,
    n: u32,
    focal: f32,
    cx: f32,
    cy: f32,
    out_ypr: *mut f32,
    out_pos: *mut f32,
    out_err: *mut f32,
) -> i32 {
    if image_pts.is_null() || out_ypr.is_null() || out_pos.is_null() {
        return 0;
    }
    let n = n as usize;
    let raw = std::slice::from_raw_parts(image_pts, n * 2);
    let pts: Vec<[f64; 2]> = (0..n).map(|i| [raw[i * 2] as f64, raw[i * 2 + 1] as f64]).collect();
    match chamber_pose::solve(&pts, focal as f64, cx as f64, cy as f64) {
        Some(p) => {
            let ypr = std::slice::from_raw_parts_mut(out_ypr, 3);
            ypr[0] = p.yaw_deg;
            ypr[1] = p.pitch_deg;
            ypr[2] = p.roll_deg;
            let pos = std::slice::from_raw_parts_mut(out_pos, 3);
            pos.copy_from_slice(&p.pos);
            if !out_err.is_null() {
                *out_err = p.reproj_err;
            }
            1
        }
        None => 0,
    }
}

/// Allocate `size` bytes inside the module's address space and return a pointer.
/// Used by the web host (AudioWorklet) to stage the asset blob and audio buffers into
/// wasm linear memory. On native it's a plain heap allocation.
///
/// # Safety: caller must pair every allocation with [`chamber_free`] using the same size.
#[no_mangle]
pub unsafe extern "C" fn chamber_alloc(size: usize) -> *mut u8 {
    let mut v = Vec::<u8>::with_capacity(size);
    let p = v.as_mut_ptr();
    std::mem::forget(v);
    p
}

/// # Safety: `ptr`/`size` must come from a prior [`chamber_alloc`].
#[no_mangle]
pub unsafe extern "C" fn chamber_free(ptr: *mut u8, size: usize) {
    if !ptr.is_null() {
        drop(Vec::from_raw_parts(ptr, 0, size));
    }
}

#[repr(C)]
pub struct ChamberPose {
    pub px: f32,
    pub py: f32,
    pub pz: f32,
    pub qw: f32,
    pub qx: f32,
    pub qy: f32,
    pub qz: f32,
}

#[repr(C)]
pub struct ChamberSource {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub gain: f32,
    pub send: f32,
}

pub struct Handle {
    r: Renderer,
    // Reusable slice table so process() builds no heap per call.
    in_refs: Vec<*const f32>,
}

/// Create a renderer from `.chamber` bytes. Returns null on parse failure.
///
/// # Safety
/// `blob` must point to `len` valid bytes for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_create(
    blob: *const u8,
    len: usize,
    sample_rate: f32,
    max_sources: u32,
    max_block: u32,
) -> *mut c_void {
    if blob.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let bytes = std::slice::from_raw_parts(blob, len);
    let asset = match ChamberAsset::parse(bytes) {
        Ok(a) => a,
        Err(_) => return std::ptr::null_mut(),
    };
    let r = Renderer::new(&asset, sample_rate, max_sources as usize, max_block as usize);
    let h = Box::new(Handle {
        r,
        in_refs: Vec::with_capacity(max_sources as usize),
    });
    Box::into_raw(h) as *mut c_void
}

/// # Safety
/// `h` must be a pointer returned by [`chamber_renderer_create`], not yet destroyed.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_destroy(h: *mut c_void) {
    if !h.is_null() {
        drop(Box::from_raw(h as *mut Handle));
    }
}

/// # Safety: `h` is a valid handle.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_set_room(h: *mut c_void, room: u32) {
    if let Some(h) = (h as *mut Handle).as_mut() {
        h.r.set_room(room as usize);
    }
}

/// # Safety: `h` is a valid handle.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_set_reflections(h: *mut c_void, on: i32) {
    if let Some(h) = (h as *mut Handle).as_mut() {
        h.r.set_reflections_enabled(on != 0);
    }
}

/// # Safety: `h` is a valid handle.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_set_master_gain(h: *mut c_void, g: f32) {
    if let Some(h) = (h as *mut Handle).as_mut() {
        h.r.set_master_gain(g);
    }
}

#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_num_rooms(h: *mut c_void) -> u32 {
    match (h as *mut Handle).as_mut() {
        Some(h) => h.r.num_rooms() as u32,
        None => 0,
    }
}

/// Render `frames` samples.
///
/// `inputs` is an array of `n` pointers, each to `frames` mono floats (one per source).
/// `out_l`/`out_r` receive `frames` floats each.
///
/// # Safety
/// All pointers must be valid for the indicated lengths for the duration of the call.
#[no_mangle]
pub unsafe extern "C" fn chamber_renderer_process(
    h: *mut c_void,
    pose: *const ChamberPose,
    sources: *const ChamberSource,
    n: u32,
    inputs: *const *const f32,
    out_l: *mut f32,
    out_r: *mut f32,
    frames: u32,
) {
    let h = match (h as *mut Handle).as_mut() {
        Some(h) => h,
        None => return,
    };
    if pose.is_null() || out_l.is_null() || out_r.is_null() {
        return;
    }
    let n = n as usize;
    let frames = frames as usize;

    let p = &*pose;
    let pose = Pose {
        position: Vec3::new(p.px, p.py, p.pz),
        orientation: Quat {
            w: p.qw,
            x: p.qx,
            y: p.qy,
            z: p.qz,
        }
        .normalized(),
    };

    // Build source list + input slice table (no heap: reuse preallocated capacity).
    let mut src_vec: Vec<Source> = Vec::with_capacity(n);
    h.in_refs.clear();
    if !sources.is_null() && !inputs.is_null() {
        let ss = std::slice::from_raw_parts(sources, n);
        let ins = std::slice::from_raw_parts(inputs, n);
        for i in 0..n {
            src_vec.push(Source {
                position: Vec3::new(ss[i].x, ss[i].y, ss[i].z),
                gain: ss[i].gain,
                send: ss[i].send,
            });
            h.in_refs.push(ins[i]);
        }
    }
    let in_slices: Vec<&[f32]> = h
        .in_refs
        .iter()
        .map(|&p| std::slice::from_raw_parts(p, frames))
        .collect();

    let ol = std::slice::from_raw_parts_mut(out_l, frames);
    let or = std::slice::from_raw_parts_mut(out_r, frames);
    h.r.process(&pose, &src_vec, &in_slices, ol, or, frames);
}
