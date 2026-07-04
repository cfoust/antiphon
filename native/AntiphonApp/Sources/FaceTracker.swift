import AVFoundation
import Combine
import CoreVideo
import QuartzCore
import Vision

struct CameraDevice: Identifiable, Hashable {
    let id: String // uniqueID
    let name: String
}

/// 1€ filter (Casiez et al.) — a velocity-adaptive low-pass. When the signal is still it uses a
/// very low cutoff (heavy smoothing, killing per-frame jitter like the near-frontal PnP flutter);
/// as the signal moves faster the cutoff rises so turns stay responsive with little lag. This is
/// what we need for single-frame PnP yaw, which is jittery at rest but must track quick head turns.
final class OneEuro {
    var minCutoff: Double, beta: Double, dCutoff: Double
    private var xPrev: Double?
    private var dxPrev = 0.0
    private var tPrev = 0.0
    init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.dCutoff = dCutoff
    }
    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
    func reset() { xPrev = nil; dxPrev = 0 }
    /// Last smoothed derivative (units/sec) — used for constant-velocity prediction.
    var velocity: Double { dxPrev }
    func filter(_ x: Double, _ t: Double) -> Double {
        guard let xp = xPrev else { xPrev = x; tPrev = t; return x }
        let dt = max(1e-3, t - tPrev)
        let dx = (x - xp) / dt
        let aD = alpha(dCutoff, dt)
        let dxHat = dxPrev + aD * (dx - dxPrev)
        let cutoff = minCutoff + beta * abs(dxHat)
        let a = alpha(cutoff, dt)
        let xHat = xp + a * (x - xp)
        xPrev = xHat; dxPrev = dxHat; tPrev = t
        return xHat
    }
}

/// Webcam → Vision head pose, with device switching, max-FPS capture, and the web
/// HeadTracker's two-point calibration → front-arc orientation + look-down whisper gate.
final class FaceTracker: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var yaw = 0.0 // radians (smoothed)
    @Published var pitch = 0.0
    @Published var roll = 0.0
    @Published var faceFound = false
    @Published var hz = 0.0
    @Published var configuredFPS = 0.0
    @Published var status = "idle"
    @Published var cameraDenied = false // TCC said no — onboarding offers the System Settings deep link
    @Published var devices: [CameraDevice] = []
    @Published var selectedID = ""

    // calibration (radians), defaults mirror the web HeadTracker
    var yawLeft = rad(-22.5)
    var span = rad(45)
    var neutralPitch = 0.0
    // Sign that maps PnP pitch onto "downward tilt" for the whisper gate. Resolved on-device:
    // looking down must raise downDeg. (false = use (pitch - neutralPitch) directly.)
    var pitchInvert = false

    var onOrient: ((Double) -> Void)? // degrees, -90…+90
    var onGate: ((Double) -> Void)? // 1 = forward, 0 = looking down
    /// Host-clock (CACurrentMediaTime) capture timestamp of the pose just published, so the audio
    /// render callback can compute the true end-to-end motion-to-sound latency.
    var onPoseStamp: ((Double) -> Void)?
    /// Debounced eye-closure result (true = eyes held closed). Fired only on change so the host can
    /// drive the immersion fade: eyes CLOSED → audio fades in, eyes OPEN → audio fades out.
    var onEyesClosed: ((Bool) -> Void)?

    // --- latency budget (plan 07) ---
    /// camera-exposure → pose-available latency (capture + Vision + solve), milliseconds.
    @Published var sensorLatencyMs = 0.0
    /// Constant-velocity yaw extrapolation horizon. Cancels part of the motion-to-sound latency on
    /// smooth turns; clamped to avoid overshoot on reversal. Set 0 to disable prediction.
    var predictLookaheadSec = 0.045
    private var framePTS = 0.0          // host-clock capture time of the current frame (seconds)
    /// Approximate 6DoF head position in metres (x = right, y = up, z = back). Estimated
    /// from the face bounding box; needs a scale prior to be truly metric (assumed face
    /// height), so treat as relative/approximate — the frame is pinned in CLAUDE.md.
    var onPosition: ((Double, Double, Double) -> Void)?
    private var sPx = 0.0, sPy = 0.0, sPz = 0.0
    private var nPx = 0.0, nPy = 0.0, nPz = 0.0, posInit = false

    /// Capture the current head position as the neutral/origin (call after calibration).
    func resetNeutral() { nPx = sPx; nPy = sPy; nPz = sPz; posInit = true }

    /// True if a saved calibration was restored, so the app can skip the two-point flow.
    @Published var hasSavedCalibration = false

    /// Persist the current calibration (yaw arc, neutral pitch, 6DoF neutral) so the user does
    /// not have to recalibrate every launch.
    func persistCalibration() {
        let d = UserDefaults.standard
        d.set(yawLeft, forKey: "cal.yawLeft")
        d.set(span, forKey: "cal.span")
        d.set(neutralPitch, forKey: "cal.neutralPitch")
        d.set(nPx, forKey: "cal.nPx"); d.set(nPy, forKey: "cal.nPy"); d.set(nPz, forKey: "cal.nPz")
        d.set(true, forKey: "cal.present")
        DispatchQueue.main.async { self.hasSavedCalibration = true }
    }

    /// Restore a previously saved calibration if present (called once at startup).
    func loadCalibration() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "cal.present") else { return }
        yawLeft = d.double(forKey: "cal.yawLeft")
        span = d.double(forKey: "cal.span")
        neutralPitch = d.double(forKey: "cal.neutralPitch")
        nPx = d.double(forKey: "cal.nPx"); nPy = d.double(forKey: "cal.nPy"); nPz = d.double(forKey: "cal.nPz")
        posInit = true
        hasSavedCalibration = true
    }

    /// Use the PnP solver (landmarks -> 6DoF). On while we validate the coordinate
    /// conventions on-device (see `debug` for the live solver output).
    var usePnP = true

    /// Live diagnostics for the PnP path (shown in the app's debug panel).
    @Published var debug = ""

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "antiphon.spike.face")
    // Rectangles request (smooth yaw/pitch, low cost) when PnP is off; the landmarks request
    // is created instead when PnP is enabled (it also yields yaw/pitch).
    private var request: VNImageBasedRequest!
    private var currentInput: AVCaptureDeviceInput?
    private var frameCount = 0
    private var lastTick = CFAbsoluteTimeGetCurrent()
    private var sYaw = 0.0, sPitch = 0.0, sRoll = 0.0
    private var imageW = 0, imageH = 0
    // 1€ filters for the angular signals. Low minCutoff → still head is rock-steady (kills the
    // near-frontal PnP ±flutter); beta lets fast turns through. Tuned for ~30–60 Hz capture.
    private let fYaw = OneEuro(minCutoff: 0.8, beta: 0.6)
    private let fPitch = OneEuro(minCutoff: 0.8, beta: 0.6)
    private let fRoll = OneEuro(minCutoff: 1.2, beta: 0.4)
    // Eye-closure → immersion fade. Native derives openness from a Vision eye-contour extent ratio
    // (web uses a 6-pt EAR); the debounced decision + shared thresholds live in EyeClosureCore. The
    // open-eye baseline is per-user, so we auto-calibrate it over the first ~1 s a face is seen —
    // the core is seeded with a placeholder until then (see handle()).
    private let eyes = EyeClosureCore(cal: .fromOpen(0.03)) // area/(width·faceH) scale; real ref auto-calibrated
    private let eyeCal = OpenEyeCalibrator()
    private var eyeCalStart = 0.0
    private var eyesCalibrated = false
    private var lastEyesClosed = false
    // The area-based openness metric is turn-robust (validated clean out to ~66° on closed.mov), so
    // this is just a backstop for extreme profile (>70°) where an eye is fully occluded and even the
    // area of the picked eye can't be trusted: past it we HOLD the last committed decision.
    private let eyeYawLimit = rad(70)

    override init() {
        super.init()
        loadCalibration()
        if usePnP {
            let req = VNDetectFaceLandmarksRequest(completionHandler: { [weak self] r, _ in self?.handle(r) })
            if #available(macOS 12.0, *) { req.revision = VNDetectFaceLandmarksRequestRevision3 }
            request = req
        } else {
            let req = VNDetectFaceRectanglesRequest(completionHandler: { [weak self] r, _ in self?.handle(r) })
            if #available(macOS 12.0, *) { req.revision = VNDetectFaceRectanglesRequestRevision3 }
            request = req
        }
    }

    private func discover() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start() {
        DispatchQueue.main.async { self.status = "requesting camera…"; self.cameraDenied = false }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.status = "camera denied — System Settings ▸ Privacy"
                    self.cameraDenied = true
                }
                return
            }
            self.queue.async {
                let found = self.discover()
                let list = found.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
                let initial = found.first { $0.position == .front } ?? found.first
                DispatchQueue.main.async {
                    self.devices = list
                    self.selectedID = initial?.uniqueID ?? ""
                }
                if let initial { self.configure(device: initial) }
            }
        }
    }

    func switchTo(_ id: String) {
        queue.async {
            guard let device = self.discover().first(where: { $0.uniqueID == id }) else { return }
            self.configure(device: device)
        }
    }

    /// Menu-bar "closed eye": stop the capture session entirely so the camera indicator
    /// goes dark. Tracking state (calibration, filters) is kept for resume().
    func pause() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.status = "paused"; self.faceFound = false }
        }
    }

    /// Menu-bar "open eye": resume watching with the previously configured device.
    func resume() {
        queue.async {
            guard !self.session.isRunning, self.currentInput != nil else { return }
            self.fYaw.reset(); self.fPitch.reset(); self.fRoll.reset()
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "tracking" }
        }
    }

    private func configure(device: AVCaptureDevice) {
        session.beginConfiguration()
        if let existing = currentInput { session.removeInput(existing) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            DispatchQueue.main.async { self.status = "couldn't open camera" }
            return
        }
        session.addInput(input)
        currentInput = input
        // On macOS, setting the device's activeFormat below auto-switches the session to
        // input-priority; we must NOT (and can't) set the preset ourselves.

        // Pin to a high-frame-rate format ONLY on the built-in camera. Continuity / DAL /
        // external cameras throw an (uncatchable) ObjC exception when you set
        // activeVideoMinFrameDuration, which would abort the app — so for those we just use
        // the device's default format/rate (plenty for head pose).
        if device.deviceType == .builtInWideAngleCamera,
           let best = device.formats.max(by: { fps($0) < fps($1) }),
           let range = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }),
           (try? device.lockForConfiguration()) != nil {
            device.activeFormat = best
            // use the format's own advertised min duration (always a valid value)
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
            let maxFps = range.maxFrameRate
            DispatchQueue.main.async { self.configuredFPS = maxFps }
        }

        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }

        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { self.status = "tracking" }
    }

    private func fps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frame capture time on the host clock (same base as CACurrentMediaTime), for the latency
        // oracle. Vision runs synchronously below, so handle() can diff against this.
        framePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        imageW = CVPixelBufferGetWidth(pixelBuffer)
        imageH = CVPixelBufferGetHeight(pixelBuffer)
        // .up: the buffer is already upright-landscape, so landmark coords come out in an
        // upright frame (nose above mouth) — .leftMirrored rotated them into a portrait frame,
        // which scrambled the min/max landmark picks and the PnP solve.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])
    }

    /// The 6 detected model landmarks in normalized image coords (0..1, y-up), for the
    /// debug overlay: [nose, chin, left-eye, right-eye, mouth-L, mouth-R].
    @Published var landmarks01: [CGPoint] = []

    // --- eye-closure debug (surfaced in TrackingDebugView) ---
    @Published var eyeOpenness = 1.0    // normalized, smoothed openness [0,1] (post-calibration)
    @Published var eyeRaw = 0.0         // raw Vision extent ratio (vert/horiz), pre-normalize
    @Published var eyesClosed = false   // debounced decision (true = held closed → scene fades in)
    @Published var eyesCalibratedPub = false
    @Published var eyeReliable = true   // false while turned too far to read the eyes (decision is held)
    @Published var leftEye01: [CGPoint] = []  // eye-contour points, normalized image coords (y-up)
    @Published var rightEye01: [CGPoint] = []
    @Published var imageAspect = 4.0 / 3.0    // capture w/h, so the overlay box matches the video exactly
    // hysteresis thresholds on the (normalized, both-eyes-mean) openness signal — live-tunable in debug.
    @Published var eyeCloseThreshold = 0.35   // openness ≤ this ⇒ CLOSED
    @Published var eyeOpenThreshold = 0.55    // openness ≥ this ⇒ OPEN
    /// Update the close/open hysteresis band (from the debug sliders).
    func setEyeThresholds(close: Double, open: Double) {
        eyeCloseThreshold = min(close, open)
        eyeOpenThreshold = max(close, open)
        eyes.setThresholds(close: eyeCloseThreshold, open: eyeOpenThreshold)
    }

    /// Eye-contour points in normalized image coords (0..1, y-up) — for the debug overlay.
    private func eyePoints01(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
        guard imageW > 0, imageH > 0,
              let pts = region?.pointsInImage(imageSize: CGSize(width: imageW, height: imageH))
        else { return [] }
        let w = Double(imageW), h = Double(imageH)
        return pts.map { CGPoint(x: $0.x / w, y: $0.y / h) }
    }

    /// Extract the 6 PnP model landmarks (pixels, model order), solve head pose, and publish
    /// diagnostics. Returns yaw (radians) + camera-frame position (metres), or nil to fall
    /// back. The coordinate conventions are being validated on-device via the debug overlay.
    private func solvePose(_ face: VNFaceObservation) -> (yaw: Double, pitch: Double, pos: (Double, Double, Double))? {
        guard imageW > 0, imageH > 0, let lm = face.landmarks else {
            DispatchQueue.main.async { self.debug = "no landmarks" }
            return nil
        }
        let w = imageW, h = imageH
        func pix(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            region?.pointsInImage(imageSize: CGSize(width: w, height: h)) ?? []
        }
        let nose = pix(lm.nose), contour = pix(lm.faceContour)
        let le = pix(lm.leftEye), re = pix(lm.rightEye), lips = pix(lm.outerLips)
        guard !nose.isEmpty, !contour.isEmpty, !le.isEmpty, !re.isEmpty, !lips.isEmpty else {
            DispatchQueue.main.async { self.debug = "missing landmark region(s)" }
            return nil
        }
        func centroid(_ pts: [CGPoint]) -> CGPoint {
            let n = CGFloat(pts.count)
            return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n)
        }
        // model order: [nose, chin, +x eye, -x eye, +x mouth, -x mouth] where +x = image-right.
        // CRITICAL: select eyes by IMAGE x-position, NOT Vision's left/right *naming*. Vision's
        // `leftEye` lands on the image LEFT in the non-mirrored .up frame, so feeding it into the
        // model's +x (image-right) slot — while the mouth corners are chosen by actual x — gives
        // the eyes the opposite handedness from the mouth, and the solve collapses to a
        // degenerate ±90° flip. Choosing both eyes and mouth by x keeps one consistent handedness.
        let noseC = centroid(nose)
        let chin = contour.min(by: { $0.y < $1.y })!     // lowest contour point (Vision y-up)
        let eyeA = centroid(le), eyeB = centroid(re)
        let eyeRight = eyeA.x > eyeB.x ? eyeA : eyeB     // image-right eye -> +x model slot
        let eyeLeft = eyeA.x > eyeB.x ? eyeB : eyeA      // image-left  eye -> -x model slot
        let mouthRight = lips.max(by: { $0.x < $1.x })!  // image-right mouth corner -> +x
        let mouthLeft = lips.min(by: { $0.x < $1.x })!   // image-left  mouth corner -> -x
        let imgPts = [noseC, chin, eyeRight, eyeLeft, mouthRight, mouthLeft]
        let norm = imgPts.map { CGPoint(x: $0.x / Double(w), y: $0.y / Double(h)) }

        // PnP input: Vision pixels are y-up; flip to y-down. No mirror (kept consistent with
        // the schematic) — true geometry, so the solve stays a proper rotation.
        var flat = [Float]()
        for pt in imgPts { flat.append(Float(pt.x)); flat.append(Float(Double(h) - pt.y)) }
        var ypr = [Float](repeating: 0, count: 3)
        var pos = [Float](repeating: 0, count: 3)
        var err: Float = 0
        let ok = flat.withUnsafeBufferPointer {
            antiphon_solve_head_pose($0.baseAddress, 6, Float(w), Float(w) / 2, Float(h) / 2, &ypr, &pos, &err)
        }
        let dbg = String(format: "img %dx%d  PnP %@  err %.1f px\nyaw %+.0f°  pitch %+.0f°  roll %+.0f°\npos  x %+.2f  y %+.2f  z %+.2f m",
                         w, h, ok == 1 ? "ok" : "FAIL", err, ypr[0], ypr[1], ypr[2], pos[0], pos[1], pos[2])
        let asp = Double(w) / Double(h)
        DispatchQueue.main.async { self.landmarks01 = norm; self.debug = dbg; self.imageAspect = asp }
        guard ok == 1, err < 25 else { return nil }
        return (yaw: rad(Double(ypr[0])), pitch: rad(Double(ypr[1])),
                pos: (Double(pos[0]), Double(pos[1]), Double(pos[2])))
    }

    /// Map measured extremes onto the front arc. yaws in radians.
    func calibrate(yawLeftRad: Double, yawRightRad: Double, neutralPitchRad: Double) {
        var s = yawRightRad - yawLeftRad
        if abs(s) < rad(8) { s = rad(45) }
        yawLeft = yawLeftRad
        span = s
        neutralPitch = neutralPitchRad
    }

    private func handle(_ request: VNRequest) {
        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTick >= 0.5 {
            let rate = Double(frameCount) / (now - lastTick)
            frameCount = 0
            lastTick = now
            DispatchQueue.main.async { self.hz = rate }
        }

        guard let face = (request.results as? [VNFaceObservation])?.first else {
            DispatchQueue.main.async { self.faceFound = false }
            return
        }
        // Pitch & roll come from Vision (its pitch drives the look-down whisper gate). YAW comes
        // from the PnP solve: Vision's own yaw is quantized to coarse buckets (~-90/0/90), which
        // is what made orientation snap. With the model proportions corrected (see antiphon-pose
        // MODEL), the PnP yaw is now smooth and passes through zero at frontal. Fall back to
        // Vision yaw only if the solve fails.
        let r = face.roll?.doubleValue ?? 0
        var visionPitch = 0.0
        if #available(macOS 12.0, *) { visionPitch = face.pitch?.doubleValue ?? 0 }

        let solved = usePnP ? solvePose(face) : nil
        let yawIn = solved?.yaw ?? (face.yaw?.doubleValue ?? 0)
        // PnP pitch (up → +, down → −, neutral ≈ +10°). Vision pitch is coarse/quantized and
        // never reliably crossed the whisper threshold; fall back to it only if the solve fails.
        let p = solved?.pitch ?? visionPitch

        sYaw = fYaw.filter(yawIn, now)
        sPitch = fPitch.filter(p, now)
        sRoll = fRoll.filter(r, now)

        // --- eye-closure → immersion fade ---
        // Vision already gave us the face + eye contours; derive openness (de-rotated by the
        // filtered head roll, radians) and run the shared debounced core. Auto-calibrate the
        // open-eye baseline like the neutral pose: assume the eyes are OPEN for the first ~1 s
        // after a face is seen, taking the median extent-ratio as the open reference. Fire the
        // callback only on a committed change so the host fade isn't re-triggered every frame.
        if imageW > 0, imageH > 0,
           let rawEye = VisionEyeOpenness.openness(
               face, imageSize: CGSize(width: imageW, height: imageH), rollRad: sRoll) {
            let tSec = CACurrentMediaTime()
            // Only trust the eyes near frontal; in profile the contours/roll are garbage and openness
            // reads a false "open". Past the limit we HOLD (skip calibration + update), so turning to
            // face an agent can't spuriously flip the fade. Gate on the INSTANTANEOUS yaw (max with
            // the smoothed one) so the hold engages the moment you turn — the filtered sYaw lags and
            // would let a fast turn slip the spike through before the gate closes.
            let reliable = max(abs(yawIn), abs(sYaw)) <= eyeYawLimit
            if reliable {
                if !eyesCalibrated {
                    if eyeCalStart == 0 { eyeCalStart = tSec }
                    eyeCal.add(rawEye)
                    if tSec - eyeCalStart >= 1.0 {
                        eyes.setCalibration(eyeCal.finish())
                        eyesCalibrated = true
                    }
                    // until calibrated, treat the eyes as open (never fade in)
                } else {
                    let closed = eyes.update(rawEye, tSec)
                    if closed != lastEyesClosed {
                        lastEyesClosed = closed
                        onEyesClosed?(closed)
                    }
                }
            }
            // publish eye-closure state + contours for the debug overlay (openness holds when unreliable)
            let leN = eyePoints01(face.landmarks?.leftEye)
            let reN = eyePoints01(face.landmarks?.rightEye)
            let op = eyes.openness, closedNow = eyes.closed, calib = eyesCalibrated
            DispatchQueue.main.async {
                self.eyeRaw = rawEye; self.eyeOpenness = op
                self.eyesClosed = closedNow; self.eyesCalibratedPub = calib
                self.leftEye01 = leN; self.rightEye01 = reN
                self.eyeReliable = reliable
            }
        }

        // Latency oracle: camera-exposure → pose-ready (capture + Vision + PnP). Smoothed for a
        // stable readout. Hand the capture timestamp to the engine so it can finish the budget
        // (pose-ready → audio-out) on the render thread.
        let sm = (CACurrentMediaTime() - framePTS) * 1000
        DispatchQueue.main.async { self.sensorLatencyMs += (sm - self.sensorLatencyMs) * 0.1 }
        onPoseStamp?(framePTS)

        // Constant-velocity yaw prediction to claw back motion-to-sound latency on smooth turns.
        // Clamp the horizon's contribution so a fast reversal can't overshoot wildly.
        let predDelta = max(-rad(12), min(rad(12), fYaw.velocity * predictLookaheadSec))
        let yawArc = sYaw + predDelta

        // map to the front arc + whisper gate (mirrors the web HeadTracker)
        let tt = (yawArc - yawLeft) / span
        onOrient?(-90 + 180 * tt)
        let downDeg = deg(sPitch - neutralPitch) * (pitchInvert ? -1 : 1)
        let amt = max(0, min(1, (downDeg - DOWN_START) / (DOWN_FULL - DOWN_START)))
        onGate?(1 - amt)

        // ---- 6DoF position ----
        let cl = { (v: Double) in max(-1.0, min(1.0, v)) }
        if let sp = solved {
            // camera frame -> world (+x right, +y up, +z back). The non-mirrored .up image moves
            // the face OPPOSITE to head translation (move head right → face goes image-left), so
            // negate camera x to make "lean right" read as +x (right) on the radar. Flip y (cam
            // +y is down) to world +y up.
            let wx = -sp.pos.0, wy = -sp.pos.1, wz = sp.pos.2
            sPx += (wx - sPx) * 0.3
            sPy += (wy - sPy) * 0.3
            sPz += (wz - sPz) * 0.3
        } else {
            // fallback: approximate 6DoF from the face bounding box
            let bb = face.boundingBox
            let faceHeightM = 0.20, vFov = 50.0 * .pi / 180, hFov = 64.0 * .pi / 180
            let ang = max(0.02, Double(bb.height)) * vFov
            let dist = (faceHeightM / 2) / tan(ang / 2)
            let cx = Double(bb.midX) - 0.5, cy = Double(bb.midY) - 0.5
            sPx += (-dist * tan(cx * hFov) - sPx) * 0.25
            sPy += (dist * tan(cy * vFov) - sPy) * 0.25
            sPz += (dist - sPz) * 0.25
        }
        if !posInit { nPx = sPx; nPy = sPy; nPz = sPz; posInit = true }
        onPosition?(cl(sPx - nPx), cl(sPy - nPy), cl(sPz - nPz))

        DispatchQueue.main.async {
            self.faceFound = true
            self.yaw = self.sYaw
            self.pitch = self.sPitch
            self.roll = self.sRoll
        }
    }
}
