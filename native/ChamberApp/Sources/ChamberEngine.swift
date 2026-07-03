import AVFoundation
import Combine
import Foundation
import QuartzCore

/// Level of the accept chime when mixed into an agent's spatialized voice. Higher than the old
/// centred level (~0.6) to offset the distance attenuation + HRTF the spatial path applies.
let CHIME_GAIN: Float = 1.3

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
    func setReverbBlend(_ b: Float) { chamber_renderer_set_reverb_blend(handle, b) }
    func setFreqScale(_ s: Float) { chamber_renderer_set_freq_scale(handle, s) }
    func setAttentionAgents(_ n: Int) { chamber_renderer_set_attention_agents(handle, UInt32(max(0, n))) }
    func setAttentionBuildMinutes(_ m: Float) { chamber_renderer_set_attention_build_minutes(handle, m) }
    func setImmersion(_ g: Float) { chamber_renderer_set_immersion(handle, g) }
    func immersion() -> Float { chamber_renderer_immersion(handle) }

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
    let x: Double // world metres (radar maps these to pixels)
    let z: Double
    let state: AgentState
    let pingAge: Double
}

/// One row of the sidebar's agent list (built on `q`, published ~2 Hz).
struct AgentListVM: Identifiable, Equatable {
    let id: Int // seat
    let name: String
    let kind: String
    let title: String
    let hex: String
    let status: String
    let lastLine: String
    let lastKind: String
    let waiting: Bool // has an unheard done-summary
    let snoozed: Bool
}

// MARK: - Per-agent runtime

final class AgentRuntime {
    let def: AgentDef
    let idx: Int
    var bearing = 0.0
    /// World position (metres, x = right, z = back; the listener origin is the
    /// calibrated neutral). Dragging on the radar moves this; bearing is derived.
    var posX: Float = 0, posZ: Float = -1.3
    /// Snoozed: still receives updates, but is invisible and silent in the world.
    var snoozed = false

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
    var chimeCur = -1, chimeTrig = 0, chimeSeen = 0  // accept chime, spatialized from this agent
    var summaryDone = false

    // state-machine fields
    var state: AgentState = .working
    var nextPing = 0.0, lastPingWall = 0.0, heardAt = 0.0
    var stNextMod = 0.0, stCurrent: Float = 0

    // live-bridge fields: presence (a bound chamberd seat) + the narration queue.
    // Queue is mutated only on the state queue; render plays via the one-shot
    // trigger pattern like ping/summary. Cap 2, drop-stale (match the web client:
    // a slow listener hears the LATEST work, not a backlog).
    var present = true // demo mode: everyone is present
    var departed = false // session gone, but its unheard done-summary keeps it in the room
    var narrQueue: [[Float]] = []
    var narr: [Float] = []
    var narrCur = -1
    var narrTrig = 0, narrSeen = 0
    var gNarr: Float = 0

    // talk-back dwell/lock earcons: the bloom is a baked rising swell gated by gBloom
    // (aborted dwell = fade out); the lock chime is a plain one-shot. Both spatialized
    // through this agent's voice like ping/chime.
    var bloom: [Float] = []
    var lockChime: [Float] = []
    var bloomCur = -1, lockCur = -1
    var bloomTrig = 0, bloomSeen = 0
    var lockTrig = 0, lockSeen = 0
    var gBloom: Float = 0

    // chord identity: each tool call plays the next of three descending notes
    // (one-shot, swapped only while idle so bursts collapse instead of
    // machine-gunning); the chord root is the "working" drone loop.
    var toolNotes: [[Float]] = []
    var toolNote: [Float] = []
    var toolIdx = 0
    var toolCur = -1, toolTrig = 0, toolSeen = 0
    var drone: [Float] = []
    var droneCur = 0
    var gDrone: Float = 0
    /// Wall time of the last sign of life (tool call or narration event) —
    /// gates the drone so idle-but-connected sessions don't hum forever.
    var lastActivity = 0.0

    // drag audition: a pulsing blip with a hot reverb send while being moved
    var pulse: [Float] = []
    var pulseCur = 0
    var gPulse: Float = 0

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
    /// Head position relative to the calibrated neutral, world metres (x=right, y=up, z=back).
    /// Published for the radar so lateral/forward head translation is visible on-screen.
    @Published var headPos = SIMD3<Double>(0, 0, 0)
    @Published var autoFinish = true
    @Published var ready = false
    @Published var roomIndex = 4 // "room (BRIR)" = room_conv — matches the web default (measured tail)
    @Published var reverbBlend = 1.0 // BRIR rooms: 0 = FDN tail, 1 = measured BRIR tail
    @Published var freqScale = 2.0   // HRTF fit: <1 / >1 warps the pinna spectral cue
    @Published var hrtfName = ""
    /// End-to-end motion-to-sound latency (ms): camera capture → pose → this audio block reaching
    /// the output. The latency oracle for plan 07 (target < ~60 ms).
    @Published var latencyMs = 0.0
    /// DEBUG: current immersion envelope gain (0 = eyes-open/silent … 1 = eyes-closed/full) and
    /// whether the fade is armed (armed only once the live experience starts).
    @Published var immersionLevel = 1.0
    @Published var immersionArmedPub = false
    @Published var immersionInvertPub = false
    /// Sidebar rows (all agents in the room, snoozed included).
    @Published var agentList: [AgentListVM] = []
    /// Seat hovered in the sidebar (highlighted in the radar); -1 = none.
    @Published var hoveredSeat = -1
    /// Menu-bar eye: false = the app is silent and not responding to eyes.
    @Published var watching = true

    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!
    private var renderer: ChamberRenderer!
    private let radius: Float = 1.3 // ~the first range ring — the distance that sounded best
    private let maxBlock = 4096

    private var agents: [AgentRuntime] = []
    private var chime: [Float] = []

    private let q = DispatchQueue(label: "chamber.state")
    private var timer: DispatchSourceTimer?

    // shared pose/look state (written by tracker, read by render + state threads)
    private var orient = 0.0
    private var headX = 0.0, headY = 0.0, headZ = 0.0
    private var lookGate = 1.0

    // Immersion envelope (eyes closed → scene full, eyes open → scene silent). Now applied
    // PER-SOURCE inside chamber-dsp (Renderer.set_immersion): the render callback just forwards the
    // 0/1 target and the engine smooths it (τ≈0.25 s) and crossfades the scene against the attention
    // cue. Parity is untouched (immersion defaults to 1.0 ⇒ every source ×1.0). `immersionArmed`
    // gates it to the live experience; before the user starts, the target holds at full so intro/
    // calibration audio is audible. `immersionInvert` swaps the eyes→fade mapping for debug testing.
    private var immersionTarget: Float = 1
    private var immersionArmed = false
    private var immersionInvert = false        // DEBUG: swap the eyes→fade mapping (test with audio)
    private var lastEyesClosedState = false     // last committed eye state, so arm/invert re-evaluate now

    // "An agent is waiting" attention cue: synthesized + spatialized INSIDE the main renderer
    // (chamber-dsp AttentionCue), crossfaded against the scene by the same immersion value — so it is
    // audible eyes-open and ducks eyes-closed, with no second renderer. We only set the agent count.
    private let attnBuildMinutes: Float = 10 // silent → full urgency over this many minutes

    // latency oracle (plan 07): capture timestamp of the latest pose + measured device output
    // latency; the render callback closes the loop and stores the end-to-end number.
    private var poseCaptureTime = 0.0
    private var outputLatencyMs = 0.0
    private var lastRenderLatencyMs = 0.0

    private var nextAuto = 0.0
    private var lingerIdx = -1, lingerStart = 0.0
    private var pubCounter = 0
    private var started = false
    private var autoFinishInternal = true
    private var lastAgentList: [AgentListVM] = []

    // menu-bar eye + room state: watching off = master gain 0 (fully silent)
    private var watchingInternal = true
    private var roomOpened = false

    // drag audition: while a dot is being moved, the chamber fades in even with
    // eyes open and the dragged agent pulses with a hot reverb send
    private var dragSeat = -1
    private var immersionHold = false
    /// Drone gate: how long after the last sign of life "working" keeps humming.
    private let droneHoldSecs = 45.0

    // live bridge (chamberd): when connected, agents exist only as bound seats and
    // speak real narration; the canned demo loops and auto-finish stay off.
    @Published var bridged = false
    private var bridge: BridgeClient?
    private var liveBridge = false
    /// Seats currently bound at the hub — tracked independently of `agents` so binds
    /// that arrive before setup() (hub replays occupancy on connect) aren't lost.
    private var boundSeats = Set<Int>()
    /// Done-summaries that arrived before setup() allocated the agents. Blips are
    /// ephemeral and may drop in that window; a done is durable state and must not.
    private var pendingDone: [Int: [Float]] = [:]

    // talk-back lock-on (eyes-closed dwell → lantern → letter). All state lives on `q`;
    // the panel (TalkbackController) is main-thread and driven via pushTalkback().
    // seatMeta/seatLines live on the engine (not AgentRuntime) so binds and narration
    // text that arrive before setup() are never lost.
    let talkback = TalkbackController()
    private var seatMeta: [Int: TalkbackSeatMeta] = [:]
    private var seatLines: [Int: [TalkbackLine]] = [:]
    private var dwellSeat = -1
    private var dwellStart = 0.0
    private var lockedSeat = -1
    /// After a dismiss, don't immediately re-dwell on the same agent — wait until the
    /// gaze leaves it or the eyes reopen (otherwise send-with-eyes-closed re-locks).
    private var cooldownSeat = -1
    private let dwellSecs = 0.9

    // preallocated FFI scratch (no allocation in the render callback)
    private var inBufs: [UnsafeMutablePointer<Float>] = []
    private var inTable: UnsafeMutablePointer<UnsafePointer<Float>?>!
    private var srcArr: UnsafeMutablePointer<ChamberSource>!

    private func now() -> Double { CFAbsoluteTimeGetCurrent() }

    init() {
        // The app owns the daemon from launch (adopt or spawn + connect /stream) —
        // before audio setup, so agents that connect while the user is still in the
        // intro/calibration flow are present the moment the room opens. All frame
        // handlers are guarded for the pre-setup (empty agents) window.
        let b = BridgeClient(engine: self)
        bridge = b
        _ = b.start()
        talkback.onSend = { [weak self] text in self?.talkbackSend(text) }
        talkback.onDismiss = { [weak self] in self?.talkbackUnlock() }
    }

    func setup() {
        guard !started, let res = Bundle.main.resourceURL else { return }
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
            a.bloom = makeBloom(PING_FREQS[i % PING_FREQS.count])
            a.lockChime = makeLockChime(PING_FREQS[i % PING_FREQS.count])
            let pf = PING_FREQS[i % PING_FREQS.count]
            a.toolNotes = toolNoteFreqs(pf).map { makeToolNote($0) }
            a.drone = makeDrone(pf)
            a.pulse = makePulse(pf)
            agents.append(a)
        }
        let n = agents.count
        let ud = UserDefaults.standard
        for (i, a) in agents.enumerated() {
            // default: the front arc at `radius`; a dragged position overrides it
            let arcBearing = n == 1 ? 0 : rad(-90 + 180 * Double(i) / Double(n - 1))
            if ud.bool(forKey: "seatpos.set.\(i)") {
                a.posX = Float(ud.double(forKey: "seatpos.x.\(i)"))
                a.posZ = Float(ud.double(forKey: "seatpos.z.\(i)"))
            } else {
                a.posX = Float(sin(arcBearing)) * radius
                a.posZ = Float(-cos(arcBearing)) * radius
            }
            a.bearing = atan2(Double(a.posX), Double(-a.posZ))
        }

        // preallocate FFI scratch
        for _ in 0..<n { inBufs.append(.allocate(capacity: maxBlock)) }
        inTable = .allocate(capacity: n)
        srcArr = .allocate(capacity: n)
        for (i, a) in agents.enumerated() {
            inTable[i] = UnsafePointer(inBufs[i])
            // fx/fy/fz zero = omnidirectional point source (legacy behaviour)
            srcArr[i] = ChamberSource(x: a.posX, y: 0,
                                      z: a.posZ, gain: 1.0, send: 0.3,
                                      fx: 0, fy: 0, fz: 0, directivity: 0, extent: 0)
        }
        renderer.setRoom(roomIndex)
        // Muted until the user enters the room (openRoom). setup() now runs at app
        // LAUNCH so live-bridge state (binds, dones) accumulates correctly from
        // second zero; the intro click just turns the speakers on.
        renderer.setMasterGain(0.0)
        renderer.setFreqScale(Float(freqScale)) // push the default "fit" so it's applied from the first block

        // attention cue: synthesized + spatialized inside the MAIN renderer now (no second engine).
        renderer.setAttentionBuildMinutes(attnBuildMinutes)

        buildGraph()
        do { try engine.start() } catch { print("[chamber] engine start: \(error)"); return }

        // Device output latency (render quantum + HW safety offset) — the tail of the budget.
        outputLatencyMs = engine.outputNode.presentationLatency * 1000
        if outputLatencyMs <= 0 { outputLatencyMs = 10 } // sane floor if the device reports 0

        started = true
        nextAuto = now() + 6
        startTimer()
        // the bridge may have entered live mode before the agents existed
        q.async { if self.liveBridge { self.applyLiveMode() } }
        DispatchQueue.main.async { self.ready = true }
    }

    /// The user entered the room (intro click): un-mute. The close 1.3 m arc + 6
    /// summed voices + BRIR tail is hot → keep the master well down.
    func openRoom() {
        q.async {
            self.roomOpened = true
            if self.watchingInternal { self.renderer?.setMasterGain(0.45) }
        }
    }

    /// Menu-bar eye. Closed (false): the app is, for all intents and purposes,
    /// silent — master gain to zero, any talk-back lock released. The caller
    /// pauses the camera; eye state simply stops arriving.
    func setWatching(_ on: Bool) {
        q.async {
            self.watchingInternal = on
            self.renderer?.setMasterGain(on && self.roomOpened ? 0.45 : 0.0)
            if !on {
                self.dwellSeat = -1
                if self.lockedSeat >= 0 {
                    self.lockedSeat = -1
                    DispatchQueue.main.async { self.talkback.dismiss(notify: false) }
                }
            }
        }
        DispatchQueue.main.async { self.watching = on }
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
            if a.chimeTrig != a.chimeSeen { a.chimeSeen = a.chimeTrig; a.chimeCur = 0 }
            if a.narrTrig != a.narrSeen { a.narrSeen = a.narrTrig; a.narrCur = 0 }
            if a.bloomTrig != a.bloomSeen { a.bloomSeen = a.bloomTrig; a.bloomCur = 0 }
            if a.lockTrig != a.lockSeen { a.lockSeen = a.lockTrig; a.lockCur = 0 }
            if a.toolTrig != a.toolSeen { a.toolSeen = a.toolTrig; a.toolCur = 0 }
            let buf = inBufs[ai]
            let gc = a.gClear, gw = a.gWhisper, gs = a.gStat, gp = a.gPing, gsum = a.gSummary, gn = a.gNarr
            let gb = a.gBloom, gd = a.gDrone, gpl = a.gPulse
            for k in 0..<n {
                var s: Float = 0
                if !a.clear.isEmpty { s += a.clear[a.clearCur] * gc; a.clearCur = (a.clearCur + 1) % a.clear.count }
                if !a.whisper.isEmpty { s += a.whisper[a.whisperCur] * gw; a.whisperCur = (a.whisperCur + 1) % a.whisper.count }
                if !a.stat.isEmpty { s += a.stat[a.statCur] * gs; a.statCur = (a.statCur + 1) % a.stat.count }
                if a.pingCur >= 0 { s += a.ping[a.pingCur] * gp; a.pingCur += 1; if a.pingCur >= a.ping.count { a.pingCur = -1 } }
                // accept chime: spatialized through this agent's voice (was a centred, in-head one-shot)
                if a.chimeCur >= 0 { s += chime[a.chimeCur] * CHIME_GAIN; a.chimeCur += 1; if a.chimeCur >= chime.count { a.chimeCur = -1 } }
                if a.summaryCur >= 0 {
                    s += a.summary[a.summaryCur] * gsum; a.summaryCur += 1
                    if a.summaryCur >= a.summary.count { a.summaryCur = -1; a.summaryDone = true }
                }
                // live narration one-shot (bridge mode)
                if a.narrCur >= 0, !a.narr.isEmpty {
                    s += a.narr[a.narrCur] * gn; a.narrCur += 1
                    if a.narrCur >= a.narr.count { a.narrCur = -1 }
                }
                // talk-back dwell bloom + lock chime (spatialized from this agent)
                if a.bloomCur >= 0 { s += a.bloom[a.bloomCur] * gb; a.bloomCur += 1; if a.bloomCur >= a.bloom.count { a.bloomCur = -1 } }
                if a.lockCur >= 0 { s += a.lockChime[a.lockCur] * 0.9; a.lockCur += 1; if a.lockCur >= a.lockChime.count { a.lockCur = -1 } }
                // chord identity: tool-call note (one-shot) + working drone (loop)
                if a.toolCur >= 0, !a.toolNote.isEmpty {
                    s += a.toolNote[a.toolCur]; a.toolCur += 1
                    if a.toolCur >= a.toolNote.count { a.toolCur = -1 }
                }
                if !a.drone.isEmpty { s += a.drone[a.droneCur] * gd; a.droneCur = (a.droneCur + 1) % a.drone.count }
                // drag audition pulse (reverb send is bumped while dragging)
                if !a.pulse.isEmpty { s += a.pulse[a.pulseCur] * gpl; a.pulseCur = (a.pulseCur + 1) % a.pulse.count }
                buf[k] = s
            }
        }

        // pose: head yaw. forward = (sin orient, 0, -cos orient) => quaternion about +y of
        // -orient (see docs/conventions.md). 6DoF head position is always fed below (true parallax).
        // Close the latency loop: this pose was captured at poseCaptureTime; it is reaching the
        // output now + the device output latency. (CACurrentMediaTime is mach-based, lock-free.)
        if poseCaptureTime > 0 {
            lastRenderLatencyMs = (CACurrentMediaTime() - poseCaptureTime) * 1000 + outputLatencyMs
        }

        // Immersion (eyes) fade + attention cue both live INSIDE the renderer now (per-source), so
        // we just forward the eyes target and the waiting-agent count before the single process()
        // call. The cue keeps building while eyes are closed (agents still waiting) — it's just
        // crossfaded to silence by the same immersion value, not reset.
        // A drag audition holds the scene fully in regardless of eye state.
        renderer.setImmersion(immersionHold ? 1 : immersionTarget)
        var waiting = 0
        for a in agents where a.state == .done && !a.snoozed { waiting += 1 } // agents wanting to summarize
        renderer.setAttentionAgents(waiting)

        let h = 0.5 * orient
        // 6DoF is always on: feed the (filtered, neutral-relative, ±1 m-clamped) head position so
        // leaning/shifting gives true motion parallax — the strongest externalization cue.
        var pose = ChamberPose(px: Float(headX), py: Float(headY), pz: Float(headZ),
                               qw: Float(cos(h)), qx: 0, qy: Float(-sin(h)), qz: 0)
        renderer.process(pose: &pose, sources: UnsafePointer(srcArr), n: agents.count,
                         inputs: UnsafePointer(inTable), outL: outL, outR: outR, frames: n)
        // Scene faded + cue crossfaded per-source inside process(); accept chime is mixed into its
        // agent's voice above (spatialized). Nothing to post-multiply.
    }

    // MARK: inputs from the head tracker

    func setOrient(deg degrees: Double) { q.async { self.orient = rad(degrees) } }
    func setLookGate(_ g: Double) { q.async { self.lookGate = max(0, min(1, g)) } }
    /// Arm the immersion fade for the live experience. Until armed the envelope stays at full so
    /// intro/calibration audio is audible; after arming, eye state drives it (see setEyesClosed).
    /// normal: eyes closed → full (1), open → silent (0). Inverted swaps it (for debug testing).
    private func immersionTargetFor(_ closed: Bool) -> Float { (closed != immersionInvert) ? 1 : 0 }
    /// Arm/disarm the immersion fade. Disarmed holds at full so intro/calibration/debug audio stays
    /// audible; armed lets eye state drive it. Live calls armImmersion(); the debug view toggles this.
    func setImmersionArmed(_ on: Bool) {
        q.async {
            self.immersionArmed = on
            self.immersionTarget = on ? self.immersionTargetFor(self.lastEyesClosedState) : 1
        }
        DispatchQueue.main.async { self.immersionArmedPub = on }
    }
    func armImmersion() { setImmersionArmed(true) }
    /// DEBUG: invert the eyes→fade mapping so eyes-OPEN fades the scene in (test the fade with audio).
    func setImmersionInvert(_ on: Bool) {
        q.async {
            self.immersionInvert = on
            if self.immersionArmed { self.immersionTarget = self.immersionTargetFor(self.lastEyesClosedState) }
        }
        DispatchQueue.main.async { self.immersionInvertPub = on }
    }
    /// Eyes CLOSED → fade the scene IN to full; eyes OPEN → fade OUT to silence. The render
    /// callback ramps toward this target per sample (click-free). No-op until armed.
    func setEyesClosed(_ closed: Bool) {
        q.async {
            self.lastEyesClosedState = closed
            if self.immersionArmed { self.immersionTarget = self.immersionTargetFor(closed) }
            if self.lockedSeat >= 0 { // lantern (closed) ↔ letter (open)
                DispatchQueue.main.async { self.talkback.setEyesClosed(closed) }
            }
        }
    }
    /// Host-clock capture time of the most recent pose (from FaceTracker), for the latency oracle.
    func setPoseStamp(_ t: Double) { q.async { self.poseCaptureTime = t } }
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
    /// 0 = parametric FDN tail, 1 = measured BRIR tail (only affects rooms that have a BRIR).
    func setReverbBlend(_ b: Double) {
        q.async { self.renderer?.setReverbBlend(Float(b)) }
        DispatchQueue.main.async { self.reverbBlend = b }
    }
    /// HRTF "fit": frequency-scale the HRTF to better match the listener's pinna (front-back cue).
    func setFreqScale(_ s: Double) {
        q.async { self.renderer?.setFreqScale(Float(s)) }
        DispatchQueue.main.async { self.freqScale = s }
    }

    // MARK: sidebar + radar interactions

    /// Snooze: the agent leaves the world (no dot, no sound) but keeps
    /// receiving updates; un-snoozing brings it back where it was.
    func setSnoozed(_ seat: Int, _ on: Bool) {
        q.async {
            guard self.agents.indices.contains(seat) else { return }
            self.agents[seat].snoozed = on
            NSLog("[snooze] seat=%d %@", seat, on ? "snoozed" : "woken")
            if on {
                // the row leaves the hovered spot without an onHover(false)
                DispatchQueue.main.async { if self.hoveredSeat == seat { self.hoveredSeat = -1 } }
                if self.dragSeat == seat { self.dragSeat = -1; self.immersionHold = false }
                if self.lockedSeat == seat {
                    self.lockedSeat = -1
                    DispatchQueue.main.async { self.talkback.dismiss(notify: false) }
                }
            }
        }
    }

    /// Sidebar hover → radar highlight.
    func setHovered(_ seat: Int) {
        DispatchQueue.main.async { if self.hoveredSeat != seat { self.hoveredSeat = seat } }
    }

    /// A dot picked up on the radar: hold the chamber audible (even with eyes
    /// open) and pulse the agent with a hot reverb send so its place is felt.
    func dragBegan(_ seat: Int) {
        q.async {
            guard self.agents.indices.contains(seat) else { return }
            self.dragSeat = seat
            self.immersionHold = true
            self.srcArr?[seat].send = 0.8
        }
    }

    /// Live position update while dragging (world metres).
    func dragMoved(_ seat: Int, x: Double, z: Double) {
        q.async { self.place(seat: seat, x: x, z: z) }
    }

    func dragEnded() {
        q.async {
            let seat = self.dragSeat
            self.dragSeat = -1
            self.immersionHold = false
            guard self.agents.indices.contains(seat) else { return }
            self.srcArr?[seat].send = 0.3
            let a = self.agents[seat]
            let ud = UserDefaults.standard
            ud.set(Double(a.posX), forKey: "seatpos.x.\(seat)")
            ud.set(Double(a.posZ), forKey: "seatpos.z.\(seat)")
            ud.set(true, forKey: "seatpos.set.\(seat)")
        }
    }

    /// Runs on `q`. Clamps to a sane annulus (too close is deafening, too far
    /// is inaudible) and keeps position, bearing and the DSP source in sync.
    private func place(seat: Int, x: Double, z: Double) {
        guard agents.indices.contains(seat) else { return }
        var wx = x, wz = z
        let d = max(sqrt(wx * wx + wz * wz), 1e-6)
        let clamped = min(max(d, 0.45), 2.6)
        wx *= clamped / d; wz *= clamped / d
        let a = agents[seat]
        a.posX = Float(wx); a.posZ = Float(wz)
        a.bearing = atan2(wx, -wz)
        srcArr?[seat].x = a.posX
        srcArr?[seat].z = a.posZ
    }

    /// A tool call from the live bridge: play the next descending chord note.
    /// Swapped only while idle, so a burst of calls collapses into one note.
    func bridgeTool(seat: Int) {
        q.async {
            guard self.agents.indices.contains(seat) else { return }
            let a = self.agents[seat]
            a.lastActivity = self.now()
            guard a.present, !a.snoozed else { return }
            if a.toolCur == -1, a.toolTrig == a.toolSeen, !a.toolNotes.isEmpty {
                a.toolNote = a.toolNotes[a.toolIdx]
                a.toolIdx = (a.toolIdx + 1) % a.toolNotes.count
                a.toolTrig += 1
            }
        }
    }

    // MARK: live bridge (chamberd /stream)

    /// First hello (or reconnect) → enter live mode: hide everyone until seats bind,
    /// stop the demo's auto-finish, drop the canned loops. Disconnect keeps live mode
    /// (agents freeze; the bridge retries in the background). Runs on `q`.
    private func applyLiveMode() {
        autoFinishInternal = false
        for (i, a) in agents.enumerated() {
            a.present = boundSeats.contains(i)
            a.state = .working
            a.clear = []; a.whisper = [] // live agents speak narration, not loops
            a.gClear = 0; a.gWhisper = 0; a.gStat = 0; a.gPing = 0
        }
        // replay dones that arrived before the room existed
        for (seat, summary) in pendingDone where agents.indices.contains(seat) {
            NSLog("[bridge] applying buffered done for seat=%d", seat)
            applyDone(agents[seat], summary: summary)
        }
        pendingDone.removeAll()
        DispatchQueue.main.async { self.bridged = true; self.autoFinish = false }
    }

    func bridgeConnected(_ up: Bool) {
        q.async {
            guard up, !self.liveBridge else { return }
            self.liveBridge = true
            self.applyLiveMode()
        }
    }

    func bridgeBind(seat: Int, agent: String? = nil, name: String? = nil, kind: String? = nil,
                    title: String? = nil, input: String? = nil) {
        q.async {
            var m = self.seatMeta[seat] ?? TalkbackSeatMeta()
            // a different session on the same seat is a new tenant — its
            // predecessor's snooze must not silence it
            var newTenant = false
            if let agent, !agent.isEmpty {
                newTenant = !m.agent.isEmpty && m.agent != agent
                m.agent = agent
            }
            if let name, !name.isEmpty { m.name = name }
            if let kind, !kind.isEmpty { m.kind = kind }
            if let title, !title.isEmpty { m.title = title }
            m.input = input ?? ""
            self.seatMeta[seat] = m
            if newTenant { self.seatLines[seat] = [] }
            if self.lockedSeat == seat { self.pushTalkback(present: false) }

            self.boundSeats.insert(seat)
            guard self.liveBridge, self.agents.indices.contains(seat) else { return }
            let a = self.agents[seat]
            a.present = true
            a.departed = false
            a.state = .working
            if newTenant { a.snoozed = false }
        }
    }

    /// Narration text (task/progress/blocked/done) — the panel's mini-transcript.
    func bridgeLine(seat: Int, kind: String, text: String) {
        q.async {
            var lines = self.seatLines[seat] ?? []
            lines.append(TalkbackLine(kind: kind, text: text, at: Date().timeIntervalSince1970))
            if lines.count > 3 { lines.removeFirst(lines.count - 3) }
            self.seatLines[seat] = lines
            if self.agents.indices.contains(seat) { self.agents[seat].lastActivity = self.now() }
            if self.lockedSeat == seat { self.pushTalkback(present: false) }
        }
    }

    func bridgeFree(seat: Int) {
        q.async {
            self.boundSeats.remove(seat)
            self.seatMeta[seat]?.input = "" // its pane may live on, but honestly: unknown
            if self.lockedSeat == seat {
                // the conversation partner left mid-compose — let the panel go
                self.lockedSeat = -1
                DispatchQueue.main.async { self.talkback.dismiss(notify: false) }
            }
            guard self.agents.indices.contains(seat) else { return }
            let a = self.agents[seat]
            a.narrQueue.removeAll()
            a.gNarr = 0
            if a.state == .done || a.state == .summarizing {
                // The session exited, but its unheard summary is the whole point of
                // the chamber: keep the agent in the room, pinging, until it's heard.
                // reset() (after .heard) then removes it.
                a.departed = true
            } else {
                a.present = false
                a.state = .working
                a.gPing = 0; a.gSummary = 0
            }
        }
    }

    /// A narration line (task/progress/blocked), already decoded to 48 k mono.
    func bridgeNarration(seat: Int, samples: [Float]) {
        q.async {
            guard self.agents.indices.contains(seat) else { return }
            let a = self.agents[seat]
            a.present = true
            if a.narrQueue.count >= 2 { a.narrQueue.removeFirst() } // drop-stale
            a.narrQueue.append(samples)
        }
    }

    /// A done-summary: swap it in for the canned summary clip and run the existing
    /// done flow (pings from its bearing, linger-to-hear, attention cue counting).
    func bridgeDone(seat: Int, summary: [Float]) {
        q.async {
            guard self.agents.indices.contains(seat) else {
                // the room doesn't exist yet (setup pending) — hold the done for it
                NSLog("[bridge] done seat=%d buffered (room not set up yet)", seat)
                self.pendingDone[seat] = summary
                return
            }
            self.applyDone(self.agents[seat], summary: summary)
        }
    }

    /// Runs on `q`. The done flow shared by live frames and the pre-setup buffer.
    private func applyDone(_ a: AgentRuntime, summary: [Float]) {
        a.present = true
        if !summary.isEmpty { a.summary = summary }
        // a fresh done may also land on a .heard agent (it finished another task);
        // only an in-flight .done/.summarizing keeps its current run
        guard a.state == .working || a.state == .heard else {
            NSLog("[bridge] done seat=%d: already \(a.state), summary updated only", a.idx)
            return
        }
        a.heardAt = 0
        a.state = .done
        a.nextPing = now() + 0.15
        a.lastPingWall = 0
        NSLog("[bridge] done seat=%d -> .done (summary %d samples)", a.idx, a.summary.count)
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

        // live narration: feed the next queued line into the one-shot slot when idle
        if liveBridge {
            for a in agents where a.present {
                if !a.snoozed, a.narrCur == -1, a.narrTrig == a.narrSeen, !a.narrQueue.isEmpty {
                    a.narr = a.narrQueue.removeFirst()
                    a.narrTrig += 1
                }
                // narration ducks like the clear voice: full when faced, murmur otherwise
                let faced = a.idx == facedIndex()
                let target: Float = (a.narr.isEmpty || a.snoozed) ? 0 : (faced ? 0.95 : 0.55) * Float(0.4 + 0.6 * lookGate)
                a.gNarr += (target - a.gNarr) * 0.15
            }
        }

        // chord drone: a quiet breathing root while the agent is actively working
        // (live mode only — recent tool call/narration keeps it alive), plus the
        // drag audition pulse for the dot being moved.
        for (i, a) in agents.enumerated() {
            let busy = liveBridge && a.present && !a.snoozed && a.state == .working
                && t - a.lastActivity < droneHoldSecs && a.lastActivity > 0
            a.gDrone += ((busy ? 0.5 : 0) - a.gDrone) * 0.03 // slow ~1.5 s fade either way
            a.gPulse += ((i == dragSeat ? 0.9 : 0) - a.gPulse) * 0.12
        }

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

        updateTalkback(fi: fi, t: t)
        updateMix(facedIdx: fi)
        publish(facedIdx: fi, at: t)
    }

    // MARK: talk-back lock-on (runs on `q`)

    /// Eyes-closed dwell → lock. Dwelling swells the agent's bloom; completing the dwell
    /// locks (chime + panel takes the keyboard). While locked, eyes-closed gaze can jump
    /// the lock to another agent via the same dwell. Eyes open freeze the lock; only the
    /// panel dismiss (esc / click-away / send) releases it.
    private func updateTalkback(fi: Int, t: Double) {
        if lastEyesClosedState {
            if fi != cooldownSeat { cooldownSeat = -1 }
            if fi >= 0, fi != lockedSeat, fi != cooldownSeat {
                if dwellSeat != fi {
                    dwellSeat = fi
                    dwellStart = t
                    agents[fi].bloomTrig += 1
                } else if t - dwellStart >= dwellSecs {
                    dwellSeat = -1
                    lock(seat: fi)
                }
            } else {
                dwellSeat = -1
            }
        } else {
            dwellSeat = -1 // eyes open: existing lock freezes, no new dwell
            cooldownSeat = -1
        }
        for (i, a) in agents.enumerated() {
            let target: Float = i == dwellSeat ? 1 : 0
            a.gBloom += (target - a.gBloom) * 0.3
        }
    }

    private func lock(seat: Int) {
        lockedSeat = seat
        if agents.indices.contains(seat) { agents[seat].lockTrig += 1 }
        NSLog("[talkback] locked seat=%d", seat)
        pushTalkback(present: true)
    }

    /// Snapshot of everything the panel shows for a seat. Runs on `q`.
    private func talkbackInfo(seat: Int) -> TalkbackAgentInfo {
        let meta = seatMeta[seat]
        let def = AGENTS[seat % AGENTS.count]
        return TalkbackAgentInfo(
            seat: seat,
            name: meta?.name ?? def.id,
            colorHex: def.hex,
            kind: meta?.kind ?? (liveBridge ? "" : "demo"),
            title: meta?.title ?? "",
            input: meta?.input ?? (liveBridge ? "" : "demo"),
            lines: seatLines[seat] ?? [])
    }

    private func pushTalkback(present: Bool) {
        guard lockedSeat >= 0 else { return }
        let info = talkbackInfo(seat: lockedSeat)
        let eyes = lastEyesClosedState
        DispatchQueue.main.async {
            if present { self.talkback.present(info: info, eyesClosed: eyes) }
            else { self.talkback.update(info: info) }
        }
    }

    /// Panel dismissed (esc / click-away / after send). Cooldown the seat so an
    /// eyes-closed send doesn't immediately re-dwell on the agent still being faced.
    func talkbackUnlock() {
        q.async {
            self.cooldownSeat = self.lockedSeat
            self.lockedSeat = -1
            self.dwellSeat = -1
        }
    }

    /// Send the user's words to the locked agent via the hub's say flow.
    func talkbackSend(_ text: String) {
        q.async {
            guard self.lockedSeat >= 0 else { return }
            if self.liveBridge {
                self.bridge?.sendSay(seat: self.lockedSeat, text: text)
            } else {
                NSLog("[talkback] (demo) say seat=%d: %@", self.lockedSeat, text)
            }
        }
    }

    /// Dev harness (CHAMBER_DEV=talkback): lock onto a fake agent with canned data so
    /// the panel's focus mechanics are testable with no daemon, camera, or agent.
    /// Presents eyes-open, so it also exercises the empty-field grace auto-dismiss.
    func talkbackHarness() {
        q.async {
            let now = Date().timeIntervalSince1970
            self.seatMeta[2] = TalkbackSeatMeta(
                name: "wren", kind: "claude-code",
                title: "chamber — talk-back panel", input: "tmux")
            self.seatLines[2] = [
                TalkbackLine(kind: "task", text: "Wiring the reconnect path in BridgeClient", at: now - 240),
                TalkbackLine(kind: "progress", text: "Backoff works; adding the respawn guard", at: now - 70),
                TalkbackLine(kind: "blocked", text: "Should the daemon keep port 8787 when the discovery file is stale?", at: now - 12),
            ]
            self.lock(seat: 2)
        }
    }

    private func facedIndex() -> Int {
        var best = -1, bd = Double.infinity
        for (i, a) in agents.enumerated() where a.present && !a.snoozed {
            let d = abs(angdiff(a.bearing, orient))
            if d < bd { bd = d; best = i }
        }
        return (best >= 0 && bd < rad(40)) ? best : -1
    }

    private func updateMix(facedIdx: Int) {
        for (i, a) in agents.enumerated() {
            if a.snoozed { // silent in the world, state machine untouched
                a.gClear += (0 - a.gClear) * 0.15
                a.gWhisper += (0 - a.gWhisper) * 0.15
                a.gStat += (0 - a.gStat) * 0.15
                continue
            }
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
    }

    // MARK: transitions

    private func finishRandom() {
        guard let a = agents.filter({ $0.state == .working }).randomElement() else { return }
        a.state = .done
        a.nextPing = now() + 0.15 + Double.random(in: 0...0.6)
        a.lastPingWall = 0
    }

    private func schedulePing(_ a: AgentRuntime, idx: Int) {
        if a.snoozed { a.gPing = 0; return } // snoozed: no pings, timer keeps cycling
        let faced = idx == facedIndex()
        a.gPing = Float((faced ? 0.9 : 0.4) * (0.5 + 0.5 * lookGate))
        a.pingTrig += 1
    }

    private func startSummary(_ a: AgentRuntime) {
        guard a.state == .done else { return }
        a.state = .summarizing
        lingerIdx = -1
        a.chimeTrig += 1  // spatial accept chime from this agent
        q.asyncAfter(deadline: .now() + 0.65) {
            guard a.state == .summarizing, !a.summary.isEmpty else { return }
            a.gSummary = 0.95
            a.summaryTrig += 1
        }
    }

    private func reset(_ a: AgentRuntime) {
        a.state = .working; a.heardAt = 0; a.stCurrent = 0; a.gPing = 0
        if a.departed { // summary heard and the session is long gone — leave the room
            a.departed = false
            a.present = false
        }
    }

    private func publish(facedIdx: Int, at t: Double) {
        pubCounter += 1
        guard pubCounter % 2 == 0 else { return }
        let vms = agents.filter { $0.present && !$0.snoozed }.map {
            AgentVM(id: $0.idx, hex: $0.def.hex, bearing: $0.bearing,
                    x: Double($0.posX), z: Double($0.posZ), state: $0.state,
                    pingAge: $0.lastPingWall > 0 ? t - $0.lastPingWall : 99)
        }
        let o = orient, g = lookGate
        let hp = SIMD3(headX, headY, headZ)
        let lat = lastRenderLatencyMs
        let imm = Double(renderer?.immersion() ?? 1) // smoothed value from the engine; benign race — fine for a debug readout
        let list = buildAgentList(at: t)
        let listChanged = list != lastAgentList
        if listChanged { lastAgentList = list }
        DispatchQueue.main.async {
            self.snapshot = vms; self.orientRad = o; self.lookGatePub = g; self.facedPub = facedIdx
            self.headPos = hp
            self.latencyMs = lat
            self.immersionLevel = imm
            if listChanged { self.agentList = list }
        }
    }

    /// Sidebar rows for everyone in the room, snoozed included. Runs on `q`.
    private func buildAgentList(at t: Double) -> [AgentListVM] {
        agents.filter { $0.present }.map { a in
            let meta = seatMeta[a.idx]
            let last = seatLines[a.idx]?.last
            // a locale-independent CODE — the sidebar localizes it (L10n.swift)
            let status: String
            switch a.state {
            case .done: status = a.departed ? "waiting.gone" : "waiting"
            case .summarizing: status = "reporting"
            case .heard: status = "resting"
            case .working:
                if !liveBridge { status = "working" }
                else if a.lastActivity > 0 && t - a.lastActivity < droneHoldSecs { status = "working" }
                else { status = "idle" }
            }
            return AgentListVM(
                id: a.idx,
                name: meta?.name ?? a.def.name,
                kind: meta?.kind ?? (liveBridge ? "" : "demo"),
                title: meta?.title ?? "",
                hex: a.def.hex,
                status: status,
                lastLine: last?.text ?? "",
                lastKind: last?.kind ?? "",
                waiting: a.state == .done,
                snoozed: a.snoozed)
        }
    }
}
