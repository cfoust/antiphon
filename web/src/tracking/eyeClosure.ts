// Eye-closure detection — shared core + MediaPipe adapter (web side).
//
// Mirrors the Chamber architecture: a PURE core (no MediaPipe, no DOM) does the
// calibration + hysteresis + blink-rejection state machine on a single normalized
// "openness" scalar in [0,1]. A thin adapter turns the tracker's raw landmarks into
// that scalar. The native side (EyeClosure.swift) runs the *same* core with the same
// thresholds; only the adapter differs (Vision eye regions vs MediaPipe mesh).
//
// Both hosts now compute the SAME yaw-invariant raw metric — eye-contour area / (width · faceH)
// — just off different landmark sources (MediaPipe mesh here, Vision eye contours on native).
// The raw values aren't numerically identical across landmark sets, but after per-user
// calibration both live in [0,1], so the openThreshold/closeThreshold/dwell below are shared
// verbatim across hosts. (See mediapipeOpenness / VisionEyeOpenness.openness for the why.)

/** A landmark in MediaPipe normalized image coords (x over width, y over height). */
export interface LM {
  x: number;
  y: number;
  z?: number;
}

// ---------------------------------------------------------------------------
// Pure core — feed it a raw openness metric per frame, get a debounced boolean.
// ---------------------------------------------------------------------------

export interface EyeClosureConfig {
  /** normalized openness at/above this ⇒ definitely OPEN (hysteresis high rail). */
  openThreshold: number;
  /** normalized openness at/below this ⇒ definitely CLOSED (hysteresis low rail). */
  closeThreshold: number;
  /** a "closed" candidate must persist this long (ms) before we commit. Must be
   *  LONGER than a natural blink (~100–150 ms) so blinks don't trip "eyes closed". */
  closeDwellMs: number;
  /** re-opening can be snappy so audio resumes fast; keep small. */
  openDwellMs: number;
  /** EWMA factor for single-frame landmark-jitter rejection (0..1, higher = snappier). */
  smooth: number;
}

export const DEFAULT_CONFIG: EyeClosureConfig = {
  openThreshold: 0.55,
  closeThreshold: 0.35, // the 0.35–0.55 band is the hysteresis dead-zone
  closeDwellMs: 300, // > blink duration → sustained closure only
  openDwellMs: 80,
  smooth: 0.5,
};

/** Per-user calibration: the raw metric when eyes are comfortably open vs fully closed. */
export interface EyeCalibration {
  openRef: number;
  closedRef: number;
}

/** If you only measured the open baseline, closed ≈ a quarter of it is a decent prior. */
export const calibrationFromOpen = (openRef: number): EyeCalibration => ({
  openRef,
  closedRef: openRef * 0.25,
});

export class EyeClosureCore {
  /** Debounced result: true = eyes held closed. */
  closed = false;
  /** Last smoothed, normalized openness in [0,1] — for a live meter/debug. */
  openness = 1;

  private smoothed = 1;
  private pending: boolean | null = null;
  private pendingSince = 0;

  constructor(
    private cal: EyeCalibration,
    private cfg: EyeClosureConfig = DEFAULT_CONFIG,
  ) {}

  setCalibration(cal: EyeCalibration): void {
    this.cal = cal;
  }

  /** Map a raw openness metric to [0,1] using the calibration span. */
  private norm(raw: number): number {
    const span = this.cal.openRef - this.cal.closedRef;
    if (Math.abs(span) < 1e-6) return 1;
    return Math.min(1, Math.max(0, (raw - this.cal.closedRef) / span));
  }

  /**
   * Feed one raw openness sample taken at tMs (monotonic, e.g. performance.now()).
   * Returns the debounced closed/open boolean.
   */
  update(raw: number, tMs: number): boolean {
    const o = this.norm(raw);
    this.smoothed += (o - this.smoothed) * this.cfg.smooth;
    this.openness = this.smoothed;

    // Hysteresis: only the two rails move the candidate; inside the band we hold state.
    let candidate = this.closed;
    if (this.smoothed <= this.cfg.closeThreshold) candidate = true;
    else if (this.smoothed >= this.cfg.openThreshold) candidate = false;

    if (candidate === this.closed) {
      this.pending = null; // candidate agrees with committed state — nothing pending
      return this.closed;
    }

    // Candidate wants to flip: require it to hold for the (direction-specific) dwell.
    const dwell = candidate ? this.cfg.closeDwellMs : this.cfg.openDwellMs;
    if (this.pending !== candidate) {
      this.pending = candidate;
      this.pendingSince = tMs;
    } else if (tMs - this.pendingSince >= dwell) {
      this.closed = candidate;
      this.pending = null;
    }
    return this.closed;
  }
}

// ---------------------------------------------------------------------------
// MediaPipe adapter — 478-pt FaceMesh landmarks → raw openness.
//
// openness = eye-contour AREA / (eye WIDTH · FACE HEIGHT) — the eye's effective vertical
// opening, made YAW-INVARIANT. Turning the head foreshortens the eye's width, which shrinks
// a plain area (→ false "closed") and inflates a vertical/width EAR (→ false "open"); dividing
// area by width cancels the foreshortening (area ≈ height·width ⇒ area/width ≈ height), and
// /faceH makes it scale-invariant. This mirrors EyeClosure.swift's metric, which was validated
// head-to-head on webcam clips as the only one with zero false-opens on closed-turns AND zero
// false-closes on open-turns.
// ---------------------------------------------------------------------------

// 6 eye-outline points for MediaPipe FaceMesh, per eye, in traversal order
// [outerCorner, topA, topB, innerCorner, bottomB, bottomA] so the shoelace area is a valid polygon.
const RIGHT_EYE = [33, 160, 158, 133, 153, 144];
const LEFT_EYE = [362, 385, 387, 263, 373, 380];

/** Shoelace polygon area (isotropic px²) of an eye outline — collapses to ~0 when the lids meet. */
function polyArea(p: LM[], w: number, h: number): number {
  let a = 0;
  for (let i = 0; i < p.length; i++) {
    const j = (i + 1) % p.length;
    a += p[i].x * w * (p[j].y * h) - p[j].x * w * (p[i].y * h);
  }
  return Math.abs(a) / 2;
}

/** Raw openness for one MediaPipe face, yaw-invariant (see header). Trusts the more frontal eye
 *  (larger width) when the head is turned enough to foreshorten one eye. */
export function mediapipeOpenness(landmarks: LM[], videoW: number, videoH: number): number {
  // face height: vertical span of the whole mesh (yaw-invariant scale)
  let mnY = Infinity, mxY = -Infinity;
  for (const p of landmarks) {
    if (p.y < mnY) mnY = p.y;
    if (p.y > mxY) mxY = p.y;
  }
  const faceH = Math.max(1, (mxY - mnY) * videoH);
  const rP = RIGHT_EYE.map((i) => landmarks[i]);
  const lP = LEFT_EYE.map((i) => landmarks[i]);
  const d = (a: LM, b: LM) => Math.hypot((a.x - b.x) * videoW, (a.y - b.y) * videoH);
  const rw = d(rP[0], rP[3]), lw = d(lP[0], lP[3]); // outer↔inner corner = eye width
  const ra = polyArea(rP, videoW, videoH), la = polyArea(lP, videoW, videoH);
  let area: number, width: number;
  const big = Math.max(lw, rw), small = Math.min(lw, rw);
  if (small > 0.6 * big) { area = 0.5 * (la + ra); width = 0.5 * (lw + rw); } // both frontal → average
  else if (lw >= rw) { area = la; width = lw; } // one turned away → trust the wider (frontal) eye
  else { area = ra; width = rw; }
  return width > 1e-6 ? area / (width * faceH) : 0;
}

// ---------------------------------------------------------------------------
// Tiny calibrator — collect open-eye samples over a hold, take the median as openRef.
// ---------------------------------------------------------------------------

export class OpenEyeCalibrator {
  private samples: number[] = [];
  add(raw: number): void {
    this.samples.push(raw);
  }
  get count(): number {
    return this.samples.length;
  }
  /** Median of the collected open-eye samples → calibration (closed via the 0.25 prior). */
  finish(): EyeCalibration {
    const s = [...this.samples].sort((a, b) => a - b);
    const openRef = s.length ? s[Math.floor(s.length / 2)] : 0.03; // area/(width·faceH) scale
    return calibrationFromOpen(openRef);
  }
}
