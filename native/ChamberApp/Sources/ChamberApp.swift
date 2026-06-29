import AVFoundation
import SwiftUI

// Shared helpers (also used by FaceTracker.swift).
func rad(_ d: Double) -> Double { d * .pi / 180 }
func deg(_ r: Double) -> Double { r * 180 / .pi }
let DOWN_START = 8.0
let DOWN_FULL = 26.0

// MARK: - Rust engine wrapper

/// Thin Swift wrapper over the chamber-ffi C ABI (libchamber_ffi.a).
final class ChamberRenderer {
    private var handle: UnsafeMutableRawPointer?
    let sampleRate: Double
    let maxBlock: Int

    init?(assetURL: URL, sampleRate: Double, maxSources: Int, maxBlock: Int) {
        self.sampleRate = sampleRate
        self.maxBlock = maxBlock
        guard let data = try? Data(contentsOf: assetURL) else { return nil }
        handle = data.withUnsafeBytes { raw -> UnsafeMutableRawPointer? in
            let p = raw.bindMemory(to: UInt8.self).baseAddress
            return chamber_renderer_create(p, data.count, Float(sampleRate),
                                           UInt32(maxSources), UInt32(maxBlock))
        }
        if handle == nil { return nil }
    }

    deinit { if let h = handle { chamber_renderer_destroy(h) } }

    var roomCount: Int { Int(chamber_renderer_num_rooms(handle)) }
    func setRoom(_ i: Int) { chamber_renderer_set_room(handle, UInt32(i)) }
    func setMasterGain(_ g: Float) { chamber_renderer_set_master_gain(handle, g) }

    /// Real-time render call. All pointers are caller-owned and valid for the call.
    @inline(__always)
    func process(pose: UnsafePointer<ChamberPose>,
                 sources: UnsafePointer<ChamberSource>, n: Int,
                 inputs: UnsafePointer<UnsafePointer<Float>?>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>,
                 frames: Int) {
        chamber_renderer_process(handle, pose, sources, UInt32(n),
                                 inputs, outL, outR, UInt32(frames))
    }
}

// MARK: - Audio engine (AVAudioSourceNode -> Rust renderer)

final class ChamberAudio: ObservableObject {
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private let renderer: ChamberRenderer

    // scene: N synthesized voices on a frontal arc
    private let nSources: Int
    private var signals: [[Float]]          // looping mono source signals
    private var cursors: [Int]
    private var positions: [ChamberSource]
    private var inBufs: [[Float]]           // preallocated per-source input blocks

    // head yaw (radians), written by the tracker thread, read by the audio thread.
    // Aligned Double load/store is atomic on arm64; benign for a demo.
    var yaw: Double = 0

    @Published var running = false
    @Published var roomIndex = 1

    init?(assetURL: URL, nSources: Int = 5) {
        let sr = 48_000.0
        let maxBlock = 2048
        guard let r = ChamberRenderer(assetURL: assetURL, sampleRate: sr,
                                      maxSources: nSources, maxBlock: maxBlock) else { return nil }
        self.renderer = r
        self.nSources = nSources
        self.signals = (0..<nSources).map { Self.voice(sr: sr, f0: 150 + 35 * Double($0)) }
        self.cursors = Array(repeating: 0, count: nSources)
        self.inBufs = (0..<nSources).map { _ in [Float](repeating: 0, count: maxBlock) }

        // place voices on a ±90° frontal arc at 2.2 m
        self.positions = (0..<nSources).map { i in
            let bearing = -Double.pi / 2 + Double.pi * Double(i) / Double(nSources - 1)
            let radius = 2.2
            return ChamberSource(x: Float(radius * sin(bearing)), y: 0,
                                 z: Float(-radius * cos(bearing)), gain: 0.9, send: 0.35)
        }
        r.setRoom(roomIndex)
        r.setMasterGain(0.9)
        buildGraph(sr: sr)
    }

    private func buildGraph(sr: Double) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                channels: 2, interleaved: false)!
        srcNode = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr in
            guard let self else { return noErr }
            let n = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let lData = abl[0].mData, let rData = abl[1].mData else { return noErr }
            let outL = lData.assumingMemoryBound(to: Float.self)
            let outR = rData.assumingMemoryBound(to: Float.self)

            // fill per-source input blocks (loop the signals)
            for s in 0..<self.nSources {
                let sig = self.signals[s]
                var c = self.cursors[s]
                self.inBufs[s].withUnsafeMutableBufferPointer { buf in
                    for i in 0..<n {
                        buf[i] = sig[c]
                        c += 1; if c >= sig.count { c = 0 }
                    }
                }
                self.cursors[s] = c
            }

            // build inputs pointer table + pose, then render
            self.inBufs.withUnsafeRawPointers { ptrs in
                var pose = self.makePose()
                self.positions.withUnsafeBufferPointer { srcs in
                    ptrs.withUnsafeBufferPointer { inPtrs in
                        self.renderer.process(pose: &pose,
                                              sources: srcs.baseAddress!, n: self.nSources,
                                              inputs: inPtrs.baseAddress!,
                                              outL: outL, outR: outR, frames: n)
                    }
                }
            }
            return noErr
        }

        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0
    }

    private func makePose() -> ChamberPose {
        let h = 0.5 * yaw
        return ChamberPose(px: 0, py: 0, pz: 0,
                           qw: Float(cos(h)), qx: 0, qy: Float(sin(h)), qz: 0)
    }

    func start() {
        guard !running else { return }
        do { try engine.start(); running = true }
        catch { print("engine start failed: \(error)") }
    }
    func stop() { engine.stop(); running = false }

    func setRoom(_ i: Int) { roomIndex = i; renderer.setRoom(i) }

    /// Voice-like mono signal (matches the offline renderer's `voice`).
    static func voice(sr: Double, f0: Double) -> [Float] {
        let n = Int(3.0 * sr)
        var out = [Float](repeating: 0, count: n)
        let harm: [(Double, Double)] = [(1, 1), (2, 0.6), (3, 0.7), (4, 0.5),
                                        (5, 0.35), (7, 0.4), (9, 0.25), (11, 0.18)]
        for i in 0..<n {
            let t = Double(i) / sr
            let vib = 1 + 0.01 * sin(2 * .pi * 5 * t)
            var s = 0.0
            for (h, a) in harm { s += a * sin(2 * .pi * f0 * h * vib * t) }
            let g = pow(0.5 - 0.5 * cos(2 * .pi * 2.6 * t), 1.5)
            out[i] = Float(0.16 * s * g)
        }
        return out
    }
}

// Helper: expose an array of `[Float]` as an array of base pointers without copying.
extension Array where Element == [Float] {
    func withUnsafeRawPointers<R>(_ body: ([UnsafePointer<Float>?]) -> R) -> R {
        func recurse(_ idx: Int, _ acc: [UnsafePointer<Float>?]) -> R {
            if idx == count { return body(acc) }
            return self[idx].withUnsafeBufferPointer { buf in
                recurse(idx + 1, acc + [buf.baseAddress])
            }
        }
        return recurse(0, [])
    }
}

// MARK: - UI

@main
struct ChamberAppMain: App {
    var body: some Scene {
        WindowGroup("Chamber") { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var tracker = FaceTracker()
    @StateObject private var audio: ChamberAudio = {
        let url = Bundle.main.url(forResource: "chamber-default", withExtension: "chamber")
            ?? URL(fileURLWithPath: "assets/baked/chamber-default.chamber")
        return ChamberAudio(assetURL: url) ?? ChamberAudio(assetURL: url)!
    }()
    @State private var manualYaw = 0.0
    @State private var useCamera = false
    private let rooms = ["dry", "room", "hall", "cathedral"]

    var body: some View {
        VStack(spacing: 14) {
            Text("Chamber — custom binaural engine (native)")
                .font(.headline)
            if useCamera {
                CameraPreview(session: tracker.session)
                    .frame(height: 200).cornerRadius(10)
                Text(String(format: "yaw %.0f°  pitch %.0f°  ·  %.0f Hz",
                            deg(tracker.yaw), deg(tracker.pitch), tracker.hz))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack {
                    Text("Head yaw (drag): \(Int(deg(manualYaw)))°")
                    Slider(value: $manualYaw, in: -(.pi/2)...(.pi/2))
                        .onChange(of: manualYaw) { _, v in audio.yaw = v }
                }
            }

            HStack {
                Button(audio.running ? "Stop" : "Start") {
                    audio.running ? audio.stop() : audio.start()
                }
                Picker("Room", selection: $audio.roomIndex) {
                    ForEach(rooms.indices, id: \.self) { Text(rooms[$0]).tag($0) }
                }.frame(width: 180)
                .onChange(of: audio.roomIndex) { _, v in audio.setRoom(v) }
                Toggle("Camera head-tracking", isOn: $useCamera)
                    .onChange(of: useCamera) { _, on in
                        if on {
                            tracker.onOrient = { deg in audio.yaw = rad(deg) }
                            tracker.start()
                        }
                    }
            }
            Text("Five voices on a frontal arc. Turn your head (or drag) — they stay world-locked.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(width: 520)
    }
}
