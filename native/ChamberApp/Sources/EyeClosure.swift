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
    private let cfg: EyeClosureConfig
    private var smoothed = 1.0
    private var pending: Bool?
    private var pendingSince = 0.0

    init(cal: EyeCalibration, cfg: EyeClosureConfig = EyeClosureConfig()) {
        self.cal = cal
        self.cfg = cfg
    }

    func setCalibration(_ c: EyeCalibration) { cal = c }

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
    /// Ordering-independent openness for one eye: (vertical extent / horizontal extent) of
    /// the contour points, de-rotated by `rollRad` so head tilt doesn't inflate the height.
    static func ratio(_ pts: [CGPoint], rollRad: Double) -> Double {
        guard pts.count >= 3 else { return 0 }
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
        let w = maxX - minX, h = maxY - minY
        return w > 1e-6 ? Double(h / w) : 0
    }

    /// Raw openness for a face = mean of both eyes' ratios. Pass the same `imageSize`/`roll`
    /// already computed in FaceTracker. Returns nil if either eye region is missing.
    static func openness(_ face: VNFaceObservation, imageSize: CGSize, rollRad: Double) -> Double? {
        guard let lm = face.landmarks,
              let le = lm.leftEye?.pointsInImage(imageSize: imageSize),
              let re = lm.rightEye?.pointsInImage(imageSize: imageSize),
              !le.isEmpty, !re.isEmpty
        else { return nil }
        return 0.5 * (ratio(le, rollRad: rollRad) + ratio(re, rollRad: rollRad))
    }
}

// MARK: - Open-eye calibrator

final class OpenEyeCalibrator {
    private var samples: [Double] = []
    var count: Int { samples.count }
    func add(_ raw: Double) { samples.append(raw) }
    func finish() -> EyeCalibration {
        let s = samples.sorted()
        let openRef = s.isEmpty ? 0.3 : s[s.count / 2] // median open-eye ratio
        return .fromOpen(openRef)
    }
}
