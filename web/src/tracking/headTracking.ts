import { FaceLandmarker, FilesetResolver } from "@mediapipe/tasks-vision";
import type { Chamber } from "../audio/engine";

// Pin the WASM runtime to the same version as the npm package (see package.json).
const VISION_VER = "0.10.14";
const WASM_URL = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${VISION_VER}/wasm`;
const MODEL_URL =
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task";

const DOWN_START = 8, // degrees of downward tilt where "all whisper" begins…
  DOWN_FULL = 26; // …and where it's fully engaged

/** Calibration: head-yaw at left (−90° bearing) and the span to right (+90°). */
export interface Calibration {
  yawLeft: number;
  span: number; // yawRight − yawLeft (signed)
  neutralPitch: number;
}

/** m = column-major 4x4 facial transform; element(row,col) = m[col*4+row]. */
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
        }
      }
    }
    requestAnimationFrame(this.loop);
  };
}
