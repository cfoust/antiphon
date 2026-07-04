// Eye-closure detection — shared core + Vision adapter (native macOS side).
//
// Same design as eye-closure.ts: a PURE core (EyeClosureCore) runs the calibration +
// hysteresis + blink-rejection state machine on a normalized openness scalar in [0,1].
// The Vision adapter turns `lm.leftEye` / `lm.rightEye` contour points into that scalar.
//
// Vision gives no blink blendshape on macOS, and its eye-contour point *ordering* isn't
// guaranteed stable across request revisions, so instead of a fixed 6-point EAR we use an
// ordering-independent extent ratio (vertical span / horizontal span of the eye contour),
// optionally de-rotated by head roll. That raw metric differs numerically from the web's
// EAR — but after per-user calibration both are in [0,1], so the thresholds below match
// eye-closure.ts VERBATIM. Keep the two DEFAULT configs in sync.

import CoreGraphics
import Foundation
import Vision

// MARK: - Pure core (mirror of EyeClosureCore in eye-closure.ts)

struct EyeClosureConfig {
    var openThreshold = 0.55   // openness ≥ this ⇒ definitely OPEN
    var closeThreshold = 0.35  // openness ≤ this ⇒ definitely CLOSED (0.35–0.55 = hysteresis band)
    var closeDwellMs = 300.0   // sustained-closure dwell; must exceed a blink (~100–150 ms)
    var openDwellMs = 80.0     // re-open fast so audio resumes promptly
    var smooth = 0.5           // EWMA jitter rejection
}

struct EyeCalibration {
    var openRef: Double
    var closedRef: Double
    /// Open-only calibration: closed ≈ a quarter of the open baseline is a decent prior.
    static func fromOpen(_ openRef: Double) -> EyeCalibration {
        EyeCalibration(openRef: openRef, closedRef: openRef * 0.25)
    }
}

final class EyeClosureCore {
    private(set) var closed = false   // debounced result: eyes held closed
    private(set) var openness = 1.0   // last smoothed normalized openness [0,1]

    private var cal: EyeCalibration
    private var cfg: EyeClosureConfig
    private var smoothed = 1.0
    private var pending: Bool?
    private var pendingSince = 0.0

    init(cal: EyeCalibration, cfg: EyeClosureConfig = EyeClosureConfig()) {
        self.cal = cal
        self.cfg = cfg
    }

    func setCalibration(_ c: EyeCalibration) { cal = c }
    var closeThreshold: Double { cfg.closeThreshold }
    var openThreshold: Double { cfg.openThreshold }
    /// Live-tune the hysteresis band (debug). `close` must stay below `open`.
    func setThresholds(close: Double, open: Double) {
        cfg.closeThreshold = min(close, open)
        cfg.openThreshold = max(close, open)
    }

    private func norm(_ raw: Double) -> Double {
        let span = cal.openRef - cal.closedRef
        if abs(span) < 1e-6 { return 1 }
        return min(1, max(0, (raw - cal.closedRef) / span))
    }

    /// Feed one raw openness sample taken at tSec (monotonic, e.g. CACurrentMediaTime()).
    @discardableResult
    func update(_ raw: Double, _ tSec: Double) -> Bool {
        let tMs = tSec * 1000
        let o = norm(raw)
        smoothed += (o - smoothed) * cfg.smooth
        openness = smoothed

        var candidate = closed
        if smoothed <= cfg.closeThreshold { candidate = true }
        else if smoothed >= cfg.openThreshold { candidate = false }

        if candidate == closed { pending = nil; return closed }

        let dwell = candidate ? cfg.closeDwellMs : cfg.openDwellMs
        if pending != candidate {
            pending = candidate
            pendingSince = tMs
        } else if tMs - pendingSince >= dwell {
            closed = candidate
            pending = nil
        }
        return closed
    }
}

// MARK: - Vision adapter (Vision eye regions → raw openness)

enum VisionEyeOpenness {
    /// De-rotated (by head roll) vertical and horizontal spans of one eye contour, in pixels.
    private static func extents(_ pts: [CGPoint], rollRad: Double) -> (v: Double, h: Double) {
        guard pts.count >= 3 else { return (0, 0) }
        let cx = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
        let cy = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
        let c = cos(-rollRad), s = sin(-rollRad)
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let rx = dx * CGFloat(c) - dy * CGFloat(s) // rotate into eye-local axes
            let ry = dx * CGFloat(s) + dy * CGFloat(c)
            minX = min(minX, rx); maxX = max(maxX, rx)
            minY = min(minY, ry); maxY = max(maxY, ry)
        }
        return (v: Double(maxY - minY), h: Double(maxX - minX))
    }

    /// Polygon area (shoelace) of an eye contour, px² — collapses toward 0 as the lids meet.
    private static func polyArea(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<pts.count { let j = (i + 1) % pts.count; a += Double(pts[i].x * pts[j].y - pts[j].x * pts[i].y) }
        return abs(a) / 2
    }

    /// Raw openness = eye-contour AREA / (contour WIDTH · FACE HEIGHT) — the eye's effective vertical
    /// opening, made YAW-INVARIANT. Turning the head foreshortens the eye's width: that shrinks the
    /// area (→ false "closed") and inflates a bbox-height ratio (→ false "open"), but dividing area by
    /// width cancels the foreshortening (area ≈ height·width, so area/width ≈ height), and /faceH makes
    /// it scale-invariant. Validated head-to-head on closed.mov + input.mov: this is the only metric
    /// with zero false-opens on closed-turns AND zero false-closes on open-turns. When one eye is
    /// occluded we trust the more frontal eye (larger width). Returns nil only if neither eye detected.
    static func openness(_ face: VNFaceObservation, imageSize: CGSize, rollRad: Double) -> Double? {
        guard let lm = face.landmarks else { return nil }
        let le = lm.leftEye?.pointsInImage(imageSize: imageSize) ?? []
        let re = lm.rightEye?.pointsInImage(imageSize: imageSize) ?? []
        let haveL = le.count >= 3, haveR = re.count >= 3
        guard haveL || haveR else { return nil }
        let faceH = max(1.0, Double(face.boundingBox.height) * Double(imageSize.height))
        let lw = haveL ? extents(le, rollRad: rollRad).h : -1
        let rw = haveR ? extents(re, rollRad: rollRad).h : -1
        let la = haveL ? polyArea(le) : 0, ra = haveR ? polyArea(re) : 0
        let area: Double, width: Double
        if haveL && haveR {
            let big = max(lw, rw), small = min(lw, rw)
            // both roughly frontal → average (less noise); one turned away → trust the wider (frontal) eye
            if small > 0.6 * big { area = 0.5 * (la + ra); width = 0.5 * (lw + rw) }
            else if lw >= rw { area = la; width = lw } else { area = ra; width = rw }
        } else if haveL { area = la; width = lw } else { area = ra; width = rw }
        guard width > 1e-6 else { return nil }
        return area / (width * faceH)
    }
}

// MARK: - Open-eye calibrator

final class OpenEyeCalibrator {
    private var samples: [Double] = []
    var count: Int { samples.count }
    func add(_ raw: Double) { samples.append(raw) }
    func finish() -> EyeCalibration {
        let s = samples.sorted()
        let openRef = s.isEmpty ? 0.03 : s[s.count / 2] // median open-eye value (area/(width·faceH) scale)
        return .fromOpen(openRef)
    }
}
