import AVFoundation
import Combine
import CoreVideo
import Vision

struct CameraDevice: Identifiable, Hashable {
    let id: String // uniqueID
    let name: String
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
    @Published var devices: [CameraDevice] = []
    @Published var selectedID = ""

    // calibration (radians), defaults mirror the web HeadTracker
    var yawLeft = rad(-22.5)
    var span = rad(45)
    var neutralPitch = 0.0
    var pitchInvert = false

    var onOrient: ((Double) -> Void)? // degrees, -90…+90
    var onGate: ((Double) -> Void)? // 1 = forward, 0 = looking down
    /// Approximate 6DoF head position in metres (x = right, y = up, z = back). Estimated
    /// from the face bounding box; needs a scale prior to be truly metric (assumed face
    /// height), so treat as relative/approximate — see docs/conventions.md.
    var onPosition: ((Double, Double, Double) -> Void)?
    private var sPx = 0.0, sPy = 0.0, sPz = 0.0

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "chamber.spike.face")
    private var request: VNDetectFaceRectanglesRequest!
    private var currentInput: AVCaptureDeviceInput?
    private var frameCount = 0
    private var lastTick = CFAbsoluteTimeGetCurrent()
    private var sYaw = 0.0, sPitch = 0.0, sRoll = 0.0

    override init() {
        super.init()
        request = VNDetectFaceRectanglesRequest(completionHandler: { [weak self] req, _ in self?.handle(req) })
        if #available(macOS 12.0, *) { request.revision = VNDetectFaceRectanglesRequestRevision3 }
    }

    private func discover() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start() {
        DispatchQueue.main.async { self.status = "requesting camera…" }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "camera denied — System Settings ▸ Privacy" }
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

        // pick the highest frame-rate format (resolution doesn't matter for pose)
        if let best = device.formats.max(by: { fps($0) < fps($1) }), fps(best) > 0 {
            try? device.lockForConfiguration()
            device.activeFormat = best
            let maxFps = fps(best)
            let dur = CMTime(value: 1, timescale: CMTimeScale(maxFps.rounded()))
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
            device.unlockForConfiguration()
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
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        try? handler.perform([request])
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
        let y = face.yaw?.doubleValue ?? 0
        let r = face.roll?.doubleValue ?? 0
        var p = 0.0
        if #available(macOS 12.0, *) { p = face.pitch?.doubleValue ?? 0 }

        let a = 0.35
        sYaw += (y - sYaw) * a
        sPitch += (p - sPitch) * a
        sRoll += (r - sRoll) * a

        // map to the front arc + whisper gate (mirrors the web HeadTracker)
        let tt = (sYaw - yawLeft) / span
        onOrient?(-90 + 180 * tt)
        let downDeg = deg(sPitch - neutralPitch) * (pitchInvert ? -1 : 1)
        let amt = max(0, min(1, (downDeg - DOWN_START) / (DOWN_FULL - DOWN_START)))
        onGate?(1 - amt)

        // approximate 6DoF position from the face bounding box (normalized image coords)
        let bb = face.boundingBox
        let faceHeightM = 0.20                       // assumed real face height (scale prior)
        let vFov = 50.0 * .pi / 180, hFov = 64.0 * .pi / 180
        let ang = max(0.02, Double(bb.height)) * vFov
        let dist = (faceHeightM / 2) / tan(ang / 2)  // metres from camera
        let cx = Double(bb.midX) - 0.5, cy = Double(bb.midY) - 0.5
        // image is leftMirrored, so +image-x is the user's left -> world −x
        let px = -dist * tan(cx * hFov)
        let py = dist * tan(cy * vFov)
        let pz = dist - 0.6                          // relative to a ~0.6 m neutral
        let pa = 0.25
        sPx += (px - sPx) * pa
        sPy += (py - sPy) * pa
        sPz += (pz - sPz) * pa
        onPosition?(sPx, sPy, sPz)

        DispatchQueue.main.async {
            self.faceFound = true
            self.yaw = self.sYaw
            self.pitch = self.sPitch
            self.roll = self.sRoll
        }
    }
}
