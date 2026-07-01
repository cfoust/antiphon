import { FaceLandmarker, FilesetResolver } from "@mediapipe/tasks-vision";
import type { Chamber } from "../audio/engine";
import {
  EyeClosureCore,
  OpenEyeCalibrator,
  calibrationFromOpen,
  mediapipeOpenness,
  type LM,
} from "./eyeClosure";

// Pin the WASM runtime to the same version as the npm package (see package.json).
const VISION_VER = "0.10.14";
const WASM_URL = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${VISION_VER}/wasm`;
const MODEL_URL =
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task";

const DOWN_START = 8, // degrees of downward tilt where "all whisper" begins…
  DOWN_FULL = 26; // …and where it's fully engaged

// How long (ms) we treat the eyes as OPEN after a face is first seen, while we collect the
// open-eye EAR baseline (mirrors the neutral-pose auto-capture). Until this completes the
// fade never engages (eyes assumed open).
const EYE_CAL_MS = 1000;
// Past this head yaw the eyes go toward profile and can't be read reliably; HOLD the last decision
// (backstop — the area/(width·faceH) metric is itself yaw-invariant across normal turns).
const EYE_YAW_LIMIT = 70;

/** Calibration: head-yaw at left (−90° bearing) and the span to right (+90°). */
export interface Calibration {
  yawLeft: number;
  span: number; // yawRight − yawLeft (signed)
  neutralPitch: number;
}

/** m = column-major 4x4 facial transform; element(row,col) = m[col*4+row].
 *  Rotation gives yaw/pitch; the translation column (m[12..14]) gives head position
 *  in the camera frame — that's the 6DoF the original app ignored. */
const decodeYawDeg = (m: number[]) => (Math.atan2(m[8], m[10]) * 180) / Math.PI;
const decodePitchDeg = (m: number[]) => (Math.atan2(-m[9], m[5]) * 180) / Math.PI;

/**
 * In-browser webcam head-pose tracking. Owns a hidden <video>, loads the
 * MediaPipe model, and (once attached + live) maps head yaw onto the front arc
 * using a measured two-point calibration. Nothing leaves the device.
 */
export class HeadTracker {
  private video = document.createElement("video");
  private landmarker: FaceLandmarker | null = null;
  private engine: Chamber | null = null;
  private running = false;
  private live = false;
  private sawFace = false;
  private onFace: (() => void) | null = null;
  private lastVideoTime = -1;
  private smoothYaw = 0;
  private smoothPitch = 0;
  // 6DoF head position from the matrix translation (camera frame), neutral-relative
  private rawPos = { x: 0, y: 0, z: 0 };
  private neutralPos = { x: 0, y: 0, z: 0 };
  private posInit = false;
  // Eye-closure → immersion fade. Web derives a yaw-invariant openness (area/(width·faceH)) from
  // the MediaPipe mesh — the SAME metric native runs on Vision contours; the debounced decision +
  // shared thresholds live in EyeClosureCore. The open-eye baseline differs per user/camera, so we
  // auto-calibrate it (see EYE_CAL_MS) — the core is seeded with a placeholder until then.
  private eyes = new EyeClosureCore(calibrationFromOpen(0.03));
  private eyeCal = new OpenEyeCalibrator();
  private eyeCalStart = 0;
  private eyesCalibrated = false;

  // calibration: head yaw at the left extreme maps to −90°, +span maps to +90°.
  yawLeft = -22.5;
  span = 45;
  neutralPitch = 0;

  constructor() {
    this.video.autoplay = true;
    this.video.muted = true;
    this.video.playsInline = true;
    this.video.setAttribute("playsinline", "");
    this.video.style.display = "none";
    document.body.appendChild(this.video);
  }

  async loadModel(): Promise<void> {
    const fileset = await FilesetResolver.forVisionTasks(WASM_URL);
    this.landmarker = await FaceLandmarker.createFromOptions(fileset, {
      baseOptions: { modelAssetPath: MODEL_URL, delegate: "GPU" },
      runningMode: "VIDEO",
      numFaces: 1,
      outputFacialTransformationMatrixes: true,
    });
  }

  async startCamera(): Promise<void> {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: 320, height: 240, facingMode: "user" },
    });
    this.video.srcObject = stream;
    await this.video.play();
  }

  /** Begin detection. `onFace` fires once, when a face is first seen. */
  startLoop(onFace: () => void): void {
    this.onFace = onFace;
    this.running = true;
    requestAnimationFrame(this.loop);
  }

  /** Current smoothed head angles — read during the calibration holds. */
  get yaw(): number {
    return this.smoothYaw;
  }
  get pitch(): number {
    return this.smoothPitch;
  }

  /** Head position (metres-ish) relative to the captured neutral pose. Right-handed,
   *  un-mirrored: +x = head moved to your right, +y = up, +z = toward the camera. */
  get pos(): { x: number; y: number; z: number } {
    const k = 0.01; // matrix translation is ~cm; scale to metres
    return {
      x: -(this.rawPos.x - this.neutralPos.x) * k, // un-mirror (camera is mirrored)
      y: (this.rawPos.y - this.neutralPos.y) * k,
      z: (this.rawPos.z - this.neutralPos.z) * k,
    };
  }

  /** Capture the current head position as the neutral/origin. */
  setNeutral(): void {
    this.neutralPos = { ...this.rawPos };
    this.posInit = true;
  }

  /** Set calibration from the two measured extremes (left, right) + neutral pitch. */
  calibrate(yawLeft: number, yawRight: number, neutralPitch: number): void {
    let span = yawRight - yawLeft;
    if (Math.abs(span) < 8) span = -45; // didn't turn enough — fall back to a default
    this.apply({ yawLeft, span, neutralPitch });
  }

  apply(c: Calibration): void {
    this.yawLeft = c.yawLeft;
    this.span = c.span;
    this.neutralPitch = c.neutralPitch;
  }

  get calibration(): Calibration {
    return { yawLeft: this.yawLeft, span: this.span, neutralPitch: this.neutralPitch };
  }

  /** Attach the engine and go live with the current calibration. */
  attach(engine: Chamber): void {
    this.engine = engine;
    this.live = true;
  }

  private loop = (): void => {
    if (!this.running || !this.landmarker) return;
    if (this.video.currentTime !== this.lastVideoTime && this.video.readyState >= 2) {
      this.lastVideoTime = this.video.currentTime;
      const res = this.landmarker.detectForVideo(this.video, performance.now());
      const mats = res.facialTransformationMatrixes;
      if (mats && mats.length) {
        const m = mats[0].data as unknown as number[];
        this.smoothYaw += (decodeYawDeg(m) - this.smoothYaw) * 0.35;
        this.smoothPitch += (decodePitchDeg(m) - this.smoothPitch) * 0.35;
        // 6DoF: smooth the translation column; snap neutral on first sight
        this.rawPos.x += (m[12] - this.rawPos.x) * 0.3;
        this.rawPos.y += (m[13] - this.rawPos.y) * 0.3;
        this.rawPos.z += (m[14] - this.rawPos.z) * 0.3;
        if (!this.posInit) this.setNeutral();
        if (!this.sawFace) {
          this.sawFace = true;
          this.onFace?.();
        }
        if (this.engine && this.live) {
          // map measured head-yaw range onto the −90°…+90° front arc
          const tt = (this.smoothYaw - this.yawLeft) / this.span;
          this.engine.setOrient(-90 + 180 * tt);
          const downDeg = this.smoothPitch - this.neutralPitch;
          const downAmt = Math.min(
            1,
            Math.max(0, (downDeg - DOWN_START) / (DOWN_FULL - DOWN_START)),
          );
          this.engine.setLookGate(1 - downAmt);
          // 6DoF head translation → true motion parallax. Convert frames: the tracker reports
          // +z = TOWARD the camera (leaning in), but the engine/radar use the chamber convention
          // front = −z, so lean-in must be −z. Without this flip, leaning in slid you backward.
          const hp = this.pos;
          this.engine.setPosition({ x: hp.x, y: hp.y, z: -hp.z });
        }

        // --- eye-closure → immersion fade ---------------------------------
        // detectForVideo already returns the 478-pt mesh every frame. Turn it into an
        // EAR-based openness and run the shared debounced core; closing your eyes fades the
        // scene IN, opening it fades OUT. Auto-calibrate the open-eye baseline like the
        // neutral-pose capture above: assume the eyes are OPEN for the first ~1 s after a
        // face is first seen and take the median EAR as the open reference.
        const lms = res.faceLandmarks?.[0];
        if (lms) {
          const raw = mediapipeOpenness(
            lms as unknown as LM[],
            this.video.videoWidth,
            this.video.videoHeight,
          );
          const nowMs = performance.now();
          // Reliability gate: past the yaw limit the eyes are in profile → HOLD (skip calibration +
          // update), so turning to face an agent can't flip the fade. Use the instantaneous yaw
          // (max with the smoothed one) so the hold engages the moment you turn.
          const reliable =
            Math.max(Math.abs(decodeYawDeg(m)), Math.abs(this.smoothYaw)) <= EYE_YAW_LIMIT;
          if (reliable) {
            if (!this.eyesCalibrated) {
              if (this.eyeCalStart === 0) this.eyeCalStart = nowMs;
              this.eyeCal.add(raw);
              if (nowMs - this.eyeCalStart >= EYE_CAL_MS) {
                this.eyes.setCalibration(this.eyeCal.finish());
                this.eyesCalibrated = true;
              }
            } else {
              this.eyes.update(raw, nowMs);
            }
          }
          // push the (held) decision; until calibrated the eyes are treated as open → never fade in
          if (this.engine && this.live) {
            this.engine.setEyesClosed(this.eyesCalibrated ? this.eyes.closed : false);
          }
        }
      }
    }
    requestAnimationFrame(this.loop);
  };
}
