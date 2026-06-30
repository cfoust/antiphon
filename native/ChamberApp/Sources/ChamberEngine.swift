import AVFoundation
import Combine
import Foundation

func rad(_ d: Double) -> Double { d * .pi / 180 }
func deg(_ r: Double) -> Double { r * 180 / .pi }
func angdiff(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return d
}

// MARK: - Rust binaural engine (chamber-ffi)

/// Thin wrapper over the chamber-ffi C ABI (statically linked libchamber_ffi.a).
final class ChamberRenderer {
    private var handle: UnsafeMutableRawPointer?
    let roomCount: Int

    init?(assetURL: URL, sampleRate: Double, maxSources: Int, maxBlock: Int) {
        guard let data = try? Data(contentsOf: assetURL) else { return nil }
        handle = data.withUnsafeBytes { raw in
            chamber_renderer_create(raw.bindMemory(to: UInt8.self).baseAddress, data.count,
                                    Float(sampleRate), UInt32(maxSources), UInt32(maxBlock))
        }
        guard let h = handle else { return nil }
        roomCount = Int(chamber_renderer_num_rooms(h))
    }
    deinit { if let h = handle { chamber_renderer_destroy(h) } }

    func setRoom(_ i: Int) { chamber_renderer_set_room(handle, UInt32(i)) }
    func setMasterGain(_ g: Float) { chamber_renderer_set_master_gain(handle, g) }

    @inline(__always)
    func process(pose: UnsafePointer<ChamberPose>, sources: UnsafePointer<ChamberSource>, n: Int,
                 inputs: UnsafePointer<UnsafePointer<Float>?>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        chamber_renderer_process(handle, pose, sources, UInt32(n), inputs, outL, outR, UInt32(frames))
    }
}

// MARK: - Radar view model

struct AgentVM: Identifiable {
    let id: Int
    let hex: String
    let bearing: Double
    let state: AgentState
    let pingAge: Double
}

// MARK: - Per-agent runtime

final class AgentRuntime {
    let def: AgentDef
    let idx: Int
    var bearing = 0.0

    // 48 kHz mono sample buffers
    var clear: [Float] = []
    var whisper: [Float] = []
    var summary: [Float] = []
    var ping: [Float] = []
    var stat: [Float] = []

    // render-thread cursors (loop beds always advance; one-shots idle at -1)
    var clearCur = 0, whisperCur = 0, statCur = 0
    var summaryCur = -1, pingCur = -1

    // gains: written by the 60 Hz state machine, read by the render thread (benign races)
    var gClear: Float = 0, gWhisper: Float = 0, gStat: Float = 0
    var gPing: Float = 0, gSummary: Float = 0

    // one-shot triggers (atomic-enough Int counters)
    var pingTrig = 0, pingSeen = 0
    var summaryTrig = 0, summarySeen = 0
    var summaryDone = false

    // state-machine fields
    var state: AgentState = .working
    var nextPing = 0.0, lastPingWall = 0.0, heardAt = 0.0
    var stNextMod = 0.0, stCurrent: Float = 0

    init(def: AgentDef, idx: Int) { self.def = def; self.idx = idx }
}

// MARK: - Chamber engine

/// The native Chamber, rendered through the custom Rust binaural engine. Six spatial voices
/// on a front arc; whisper bed with a single faced "winner"; look down → everyone whispers;
/// done → ping from its bearing; linger → chime + spoken summary; heard → faint static;
/// auto-finish on a timer. HRTF + room reverb come from chamber-dsp (measured HRTF asset).
final class ChamberEngine: ObservableObject {
    @Published var snapshot: [AgentVM] = []
    @Published var orientRad = 0.0
    @Published var lookGatePub = 1.0
    @Published var facedPub = -1
    @Published var autoFinish = true
    @Published var ready = false
    @Published var roomIndex = 4 // "room (BRIR)" — the measured-style convolution room
    @Published var hrtfName = ""
    @Published var use6DoF = false   // webcam position estimate is crude → opt-in

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var renderer: ChamberRenderer!
    private let radius: Float = 1.3 // ~the first range ring — the distance that sounded best
    private let maxBlock = 4096

    private var agents: [AgentRuntime] = []
    private var chime: [Float] = []
    private var chimeCur = -1, chimeTrig = 0, chimeSeen = 0
    private var gChime: Float = 0

    private let q = DispatchQueue(label: "chamber.state")
    private var timer: DispatchSourceTimer?

    // shared pose/look state (written by tracker, read by render + state threads)
    private var orient = 0.0
    private var headX = 0.0, headY = 0.0, headZ = 0.0
    private var lookGate = 1.0

    private var nextAuto = 0.0
    private var lingerIdx = -1, lingerStart = 0.0
    private var pubCounter = 0
    private var started = false
    private var autoFinishInternal = true
    private var use6DoFInternal = false

    // preallocated FFI scratch (no allocation in the render callback)
    private var inBufs: [UnsafeMutablePointer<Float>] = []
    private var inTable: UnsafeMutablePointer<UnsafePointer<Float>?>!
    private var srcArr: UnsafeMutablePointer<ChamberSource>!

    private func now() -> Double { CFAbsoluteTimeGetCurrent() }

    func setup() {
        guard let res = Bundle.main.resourceURL else { return }
        let assetURL = res.appendingPathComponent("chamber.chamber")
        guard let r = ChamberRenderer(assetURL: assetURL, sampleRate: SAMPLE_RATE,
                                      maxSources: AGENTS.count, maxBlock: maxBlock) else {
            print("[chamber] failed to load renderer/asset"); return
        }
        renderer = r
        DispatchQueue.main.async { self.hrtfName = (try? String(contentsOf: res.appendingPathComponent("hrtf.txt"))) ?? "" }

        // load voices + synthesize earcons
        let base = res.appendingPathComponent("audio")
        chime = makeChime()
        let sharedStatic = makeStatic()
        for (i, def) in AGENTS.enumerated() {
            let a = AgentRuntime(def: def, idx: i)
            let work = loadMono(base.appendingPathComponent("\(def.id).mp3")) ?? []
            a.clear = work
            a.whisper = work.isEmpty ? [] : whispered(work)
            a.summary = loadMono(base.appendingPathComponent("\(def.id)_done.mp3")) ?? []
            a.ping = makePing(PING_FREQS[i % PING_FREQS.count])
            a.stat = sharedStatic
            agents.append(a)
        }
        let n = agents.count
        for (i, a) in agents.enumerated() {
            a.bearing = n == 1 ? 0 : rad(-90 + 180 * Double(i) / Double(n - 1))
        }

        // preallocate FFI scratch
        for _ in 0..<n { inBufs.append(.allocate(capacity: maxBlock)) }
        inTable = .allocate(capacity: n)
        srcArr = .allocate(capacity: n)
        for (i, a) in agents.enumerated() {
            inTable[i] = UnsafePointer(inBufs[i])
            srcArr[i] = ChamberSource(x: Float(sin(a.bearing)) * radius, y: 0,
                                      z: Float(-cos(a.bearing)) * radius, gain: 1.0, send: 0.3)
        }
        renderer.setRoom(roomIndex)
        renderer.setMasterGain(0.78) // tamed: BRIR reverb adds a lot of perceived loudness

        buildGraph()
        do { try engine.start() } catch { print("[chamber] engine start: \(error)"); return }

        started = true
        nextAuto = now() + 6
        startTimer()
        DispatchQueue.main.async { self.ready = true }
    }

    private func buildGraph() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
                                channels: 2, interleaved: false)!
        srcNode = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, ablPtr in
            guard let self else { return noErr }
            let nframes = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            guard let lData = abl[0].mData, let rData = abl[1].mData else { return noErr }
            let outL = lData.assumingMemoryBound(to: Float.self)
            let outR = rData.assumingMemoryBound(to: Float.self)
            self.render(outL: outL, outR: outR, n: min(nframes, self.maxBlock))
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        engine.mainMixerNode.outputVolume = 1.0
    }

    // MARK: render callback (audio thread)

    private func render(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, n: Int) {
        // mix each agent's active signals into its mono input buffer
        for (ai, a) in agents.enumerated() {
            if a.pingTrig != a.pingSeen { a.pingSeen = a.pingTrig; a.pingCur = 0 }
            if a.summaryTrig != a.summarySeen { a.summarySeen = a.summaryTrig; a.summaryCur = 0 }
            let buf = inBufs[ai]
            let gc = a.gClear, gw = a.gWhisper, gs = a.gStat, gp = a.gPing, gsum = a.gSummary
            for k in 0..<n {
                var s: Float = 0
                if !a.clear.isEmpty { s += a.clear[a.clearCur] * gc; a.clearCur = (a.clearCur + 1) % a.clear.count }
                if !a.whisper.isEmpty { s += a.whisper[a.whisperCur] * gw; a.whisperCur = (a.whisperCur + 1) % a.whisper.count }
                if !a.stat.isEmpty { s += a.stat[a.statCur] * gs; a.statCur = (a.statCur + 1) % a.stat.count }
                if a.pingCur >= 0 { s += a.ping[a.pingCur] * gp; a.pingCur += 1; if a.pingCur >= a.ping.count { a.pingCur = -1 } }
                if a.summaryCur >= 0 {
                    s += a.summary[a.summaryCur] * gsum; a.summaryCur += 1
                    if a.summaryCur >= a.summary.count { a.summaryCur = -1; a.summaryDone = true }
                }
                buf[k] = s
            }
        }

        // pose: head yaw. forward = (sin orient, 0, -cos orient) => quaternion about +y of
        // -orient (see docs/conventions.md). Listener stays at the origin unless 6DoF is on
        // (the webcam position estimate is crude and otherwise mislocalizes everything).
        let h = 0.5 * orient
        let p6 = use6DoFInternal
        var pose = ChamberPose(px: p6 ? Float(headX) : 0, py: p6 ? Float(headY) : 0,
                               pz: p6 ? Float(headZ) : 0,
                               qw: Float(cos(h)), qx: 0, qy: Float(-sin(h)), qz: 0)
        renderer.process(pose: &pose, sources: UnsafePointer(srcArr), n: agents.count,
                         inputs: UnsafePointer(inTable), outL: outL, outR: outR, frames: n)

        // chime: non-spatial one-shot, added centred
        if chimeTrig != chimeSeen { chimeSeen = chimeTrig; chimeCur = 0 }
        if chimeCur >= 0 {
            for k in 0..<n where chimeCur >= 0 {
                let c = chime[chimeCur] * gChime
                outL[k] += c; outR[k] += c
                chimeCur += 1; if chimeCur >= chime.count { chimeCur = -1 }
            }
        }
    }

    // MARK: inputs from the head tracker

    func setOrient(deg degrees: Double) { q.async { self.orient = rad(degrees) } }
    func setLookGate(_ g: Double) { q.async { self.lookGate = max(0, min(1, g)) } }
    func setPosition(_ x: Double, _ y: Double, _ z: Double) {
        q.async { self.headX = x; self.headY = y; self.headZ = z }
    }
    func setAutoFinish(_ on: Bool) {
        q.async { self.autoFinishInternal = on }
        DispatchQueue.main.async { self.autoFinish = on }
    }
    func finishOne() { q.async { self.finishRandom() } }
    func setRoom(_ i: Int) {
        q.async { self.renderer?.setRoom(i) }
        DispatchQueue.main.async { self.roomIndex = i }
    }
    func setUse6DoF(_ on: Bool) {
        q.async { self.use6DoFInternal = on }
        DispatchQueue.main.async { self.use6DoF = on }
    }

    // MARK: the loop

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard started else { return }
        let t = now()
        for (i, a) in agents.enumerated() {
            switch a.state {
            case .done:
                if t >= a.nextPing { schedulePing(a, idx: i); a.lastPingWall = t; a.nextPing = t + PING_INTERVAL }
            case .summarizing:
                if a.summaryDone { a.summaryDone = false; a.state = .heard; a.heardAt = t; a.gSummary = 0 }
            case .heard:
                if a.heardAt != 0, t - a.heardAt > RECYCLE_SECS { reset(a) }
                else if t >= a.stNextMod {
                    a.stNextMod = t + 0.12 + Double.random(in: 0...0.38)
                    a.stCurrent = Double.random(in: 0...1) < 0.45 ? 0 : Float.random(in: 0.25...1.0)
                }
            default: break
            }
        }

        if autoFinishInternal, t >= nextAuto {
            nextAuto = t + AUTO_FINISH_MIN + Double.random(in: 0...(AUTO_FINISH_MAX - AUTO_FINISH_MIN))
            finishRandom()
        }

        let fi = facedIndex()
        if fi >= 0, lookGate > 0.6, agents[fi].state == .done {
            if lingerIdx != fi { lingerIdx = fi; lingerStart = t }
            else if t - lingerStart >= LINGER_SECS { startSummary(agents[fi]) }
        } else { lingerIdx = -1 }

        updateMix(facedIdx: fi)
        publish(facedIdx: fi, at: t)
    }

    private func facedIndex() -> Int {
        var best = -1, bd = Double.infinity
        for (i, a) in agents.enumerated() {
            let d = abs(angdiff(a.bearing, orient))
            if d < bd { bd = d; best = i }
        }
        return (best >= 0 && bd < rad(40)) ? best : -1
    }

    private func updateMix(facedIdx: Int) {
        for (i, a) in agents.enumerated() {
            let faced = i == facedIdx
            let front = (cos(angdiff(a.bearing, orient)) + 1) / 2
            var clear: Float = 0, whisper: Float = 0, stat: Float = 0
            switch a.state {
            case .working:
                let murmur = 0.06, g = lookGate
                if faced {
                    let level = murmur + (1 - murmur) * g
                    let w = 1 - g
                    clear = Float(level * (1 - w)); whisper = Float(level * w)
                } else {
                    whisper = Float(murmur * (0.82 + 0.18 * front))
                }
            case .heard:
                stat = faced ? Float(0.1 * lookGate) * a.stCurrent : 0
            default: break
            }
            a.gClear += (clear - a.gClear) * 0.15
            a.gWhisper += (whisper - a.gWhisper) * 0.15
            a.gStat += (stat - a.gStat) * 0.15
        }
        gChime += (0 - gChime) * 0.02 // decays after each trigger sets it high
    }

    // MARK: transitions

    private func finishRandom() {
        guard let a = agents.filter({ $0.state == .working }).randomElement() else { return }
        a.state = .done
        a.nextPing = now() + 0.15 + Double.random(in: 0...0.6)
        a.lastPingWall = 0
    }

    private func schedulePing(_ a: AgentRuntime, idx: Int) {
        let faced = idx == facedIndex()
        a.gPing = Float((faced ? 0.9 : 0.4) * (0.5 + 0.5 * lookGate))
        a.pingTrig += 1
    }

    private func startSummary(_ a: AgentRuntime) {
        guard a.state == .done else { return }
        a.state = .summarizing
        lingerIdx = -1
        gChime = 0.6
        chimeTrig += 1
        q.asyncAfter(deadline: .now() + 0.65) {
            guard a.state == .summarizing, !a.summary.isEmpty else { return }
            a.gSummary = 0.95
            a.summaryTrig += 1
        }
    }

    private func reset(_ a: AgentRuntime) {
        a.state = .working; a.heardAt = 0; a.stCurrent = 0; a.gPing = 0
    }

    private func publish(facedIdx: Int, at t: Double) {
        pubCounter += 1
        guard pubCounter % 2 == 0 else { return }
        let vms = agents.map {
            AgentVM(id: $0.idx, hex: $0.def.hex, bearing: $0.bearing, state: $0.state,
                    pingAge: $0.lastPingWall > 0 ? t - $0.lastPingWall : 99)
        }
        let o = orient, g = lookGate
        DispatchQueue.main.async {
            self.snapshot = vms; self.orientRad = o; self.lookGatePub = g; self.facedPub = facedIdx
        }
    }
}
