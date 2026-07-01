/* Chamber binaural renderer — C ABI (see crates/chamber-ffi).
 * Hand-written to match the #[no_mangle] exports. Keep in sync with that crate. */
#ifndef CHAMBER_H
#define CHAMBER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ChamberPose {
    float px, py, pz;     /* listener position (world metres) */
    float qw, qx, qy, qz; /* orientation quaternion */
} ChamberPose;

typedef struct ChamberSource {
    float x, y, z;        /* source position (world metres) */
    float gain;           /* linear pre-gain */
    float send;           /* reverb send 0..1 */
} ChamberSource;

/* Opaque handle. */
typedef void ChamberRenderer;

ChamberRenderer *chamber_renderer_create(const uint8_t *blob, size_t len,
                                         float sample_rate,
                                         uint32_t max_sources, uint32_t max_block);
void chamber_renderer_destroy(ChamberRenderer *h);
void chamber_renderer_set_room(ChamberRenderer *h, uint32_t room);
void chamber_renderer_set_reflections(ChamberRenderer *h, int32_t on);
void chamber_renderer_set_master_gain(ChamberRenderer *h, float g);
/* Late-tail blend for BRIR rooms: 0 = pure parametric FDN, 1 = pure measured BRIR. */
void chamber_renderer_set_reverb_blend(ChamberRenderer *h, float b);
/* HRTF frequency-scaling / "fit": 1.0 = baked HRTF; >1 shifts pinna cues up, <1 down. */
void chamber_renderer_set_freq_scale(ChamberRenderer *h, float s);
/* "An agent is waiting" cue: number of waiting agents (0 = silent, resets the build clock). */
void chamber_renderer_set_attention_agents(ChamberRenderer *h, uint32_t n);
/* Minutes over which the attention cue builds from silent -> full urgency (louder + faster). */
void chamber_renderer_set_attention_build_minutes(ChamberRenderer *h, float m);
uint32_t chamber_renderer_num_rooms(ChamberRenderer *h);

/* Render `frames` samples. `inputs` is `n` pointers to `frames` mono floats each. */
void chamber_renderer_process(ChamberRenderer *h, const ChamberPose *pose,
                              const ChamberSource *sources, uint32_t n,
                              const float *const *inputs,
                              float *out_l, float *out_r, uint32_t frames);

/* 6DoF head pose from facial landmarks (PnP). image_pts = 2*n pixel coords (x,y) in the
 * model order: nose tip, chin, left-eye outer, right-eye outer, left-mouth, right-mouth.
 * Writes yaw/pitch/roll (deg) to out_ypr[3], camera-frame position (m) to out_pos[3],
 * mean reprojection error (px) to out_err[1]. Returns 1 on success, 0 on failure. */
int32_t chamber_solve_head_pose(const float *image_pts, uint32_t n,
                                float focal, float cx, float cy,
                                float *out_ypr, float *out_pos, float *out_err);

#ifdef __cplusplus
}
#endif
#endif /* CHAMBER_H */
