import AppKit
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

// MARK: - Rust binaural engine (antiphon-ffi)

/// Thin wrapper over the antiphon-ffi C ABI (statically linked libantiphon_ffi.a).
final class AntiphonRenderer {
    private var handle: UnsafeMutableRawPointer?
    let roomCount: Int

    init?(assetURL: URL, sampleRate: Double, maxSources: Int, maxBlock: Int) {
        guard let data = try? Data(contentsOf: assetURL) else { return nil }
        handle = data.withUnsafeBytes { raw in
            antiphon_renderer_create(raw.bindMemory(to: UInt8.self).baseAddress, data.count,
                                    Float(sampleRate), UInt32(maxSources), UInt32(maxBlock))
        }
        guard let h = handle else { return nil }
        roomCount = Int(antiphon_renderer_num_rooms(h))
    }
    deinit { if let h = handle { antiphon_renderer_destroy(h) } }

    func setRoom(_ i: Int) { antiphon_renderer_set_room(handle, UInt32(i)) }
    func setMasterGain(_ g: Float) { antiphon_renderer_set_master_gain(handle, g) }
    func setReverbBlend(_ b: Float) { antiphon_renderer_set_reverb_blend(handle, b) }
    func setFreqScale(_ s: Float) { antiphon_renderer_set_freq_scale(handle, s) }
    func setAttentionAgents(_ n: Int) { antiphon_renderer_set_attention_agents(handle, UInt32(max(0, n))) }
    func setAttentionBuildMinutes(_ m: Float) { antiphon_renderer_set_attention_build_minutes(handle, m) }
    func setImmersion(_ g: Float) { antiphon_renderer_set_immersion(handle, g) }
    /// Footprint of a room preset (width, height, depth in metres), or nil.
    func roomDims(_ room: Int) -> SIMD3<Float>? {
        var out: [Float] = [0, 0, 0]
        guard antiphon_renderer_room_dims(handle, UInt32(room), &out) != 0 else { return nil }
        return SIMD3(out[0], out[1], out[2])
    }
    func immersion() -> Float { antiphon_renderer_immersion(handle) }

    @inline(__always)
    func process(pose: UnsafePointer<AntiphonPose>, sources: UnsafePointer<AntiphonSource>, n: Int,
                 inputs: UnsafePointer<UnsafePointer<Float>?>,
                 outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frames: Int) {
        antiphon_renderer_process(handle, pose, sources, UInt32(n), inputs, outL, outR, UInt32(frames))
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
    let title: String
    let lastLine: String // most recent narration — the radar's hover bubble
    let lastAt: TimeInterval // when it was said (the bubble shows the age)
}

/// One row of the sidebar's agent list (built on `q`, published ~2 Hz).
struct AgentListVM: Identifiable, Equatable {
    let id: Int // seat
    let name: String
    let kind: String
    let title: String
    let repo: String
    let cwd: String
    let branch: String
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
    var chime: [Float] = [] // accept chime, in this agent's key (ping note + fifth)

    // render-thread cursors (loop beds always advance; one-shots idle at -1)
    var clearCur = 0, whisperCur = 0
    var summaryCur = -1, pingCur = -1

    // gains: written by the 60 Hz state machine, read by the render thread (benign races)
    var gClear: Float = 0, gWhisper: Float = 0
    var gPing: Float = 0, gSummary: Float = 0

    // one-shot triggers (atomic-enough Int counters)
    var pingTrig = 0, pingSeen = 0
    var summaryTrig = 0, summarySeen = 0
    var chimeCur = -1, chimeTrig = 0, chimeSeen = 0  // accept chime, spatialized from this agent
    var summaryDone = false

    // state-machine fields
    var state: AgentState = .working
    var nextPing = 0.0, lastPingWall = 0.0, heardAt = 0.0

    // live-bridge fields: presence (a bound antiphond seat) + the narration queue.
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

    // talk-back dwell/lock hum: one seamless chord-root loop; ALL of its shape
    // (build during dwell, brief crest at lock, release) lives in gBloom.
    // Spatialized through this agent's voice like ping/chime.
    var bloom: [Float] = []
    var bloomCur = 0
    var gBloom: Float = 0
    /// Wall time of the lock — the hum leans up for a moment after this.
    var crestAt = 0.0
    /// The hum is a presence reminder — lovely once per sweep, cloying on
    /// repeat. Per-agent: it sounds at most once per cooldown; the dwell/lock
    /// mechanics keep working silently in between.
    var lastBloomAt = 0.0
    var bloomLive = false // this dwell's hum is sounding (not cooled down)

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

// MARK: - Antiphon engine

/// The native Antiphon, rendered through the custom Rust binaural engine. Six spatial voices
/// on a front arc; whisper bed with a single faced "winner"; look down → everyone whispers;
/// done → ping from its bearing; linger → chime + spoken summary; heard → faint static;
/// auto-finish on a timer. HRTF + room reverb come from antiphon-dsp (measured HRTF asset).
final class AntiphonEngine: ObservableObject {
    @Published var snapshot: [AgentVM] = []
    @Published var orientRad = 0.0
    @Published var lookGatePub = 1.0
    @Published var facedPub = -1
    /// Head position relative to the calibrated neutral, world metres (x=right, y=up, z=back).
    /// Published for the radar so lateral/forward head translation is visible on-screen.
    @Published var headPos = SIMD3<Double>(0, 0, 0)
    @Published var autoFinish = true
    @Published var ready = false
    @Published var roomIndex = 5 // hall (BRIR) — the antiphon's one true acoustic (picker removed)
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
    private var renderer: AntiphonRenderer!
    private let radius: Float = 1.3 // ~the first range ring — the distance that sounded best
    /// Per-voice reverb send. Low on purpose: the hall answers faintly behind
    /// close voices instead of washing them. Everything — the drag pulse
    /// included — stays this dry.
    private let voiceSend: Float = 0.05
    private let maxBlock = 4096

    private var agents: [AgentRuntime] = []

    private let q = DispatchQueue(label: "antiphon.state")
    private var timer: DispatchSourceTimer?

    // shared pose/look state (written by tracker, read by render + state threads)
    private var orient = 0.0
    private var headX = 0.0, headY = 0.0, headZ = 0.0
    private var lookGate = 1.0

    // Immersion envelope (eyes closed → scene full, eyes open → scene silent). Now applied
    // PER-SOURCE inside antiphon-dsp (Renderer.set_immersion): the render callback just forwards the
    // 0/1 target and the engine smooths it (τ≈0.25 s) and crossfades the scene against the attention
    // cue. Parity is untouched (immersion defaults to 1.0 ⇒ every source ×1.0). `immersionArmed`
    // gates it to the live experience; before the user starts, the target holds at full so intro/
    // calibration audio is audible. `immersionInvert` swaps the eyes→fade mapping for debug testing.
    private var roomIndexQ = 5 // q-side copy of the active room (bounds for drag)
    // The eyes-open "agents are waiting" chord. Off = the room stays silent
    // until you choose to close your eyes; the sidebar's gold dots remain.
    private var attentionEnabled = UserDefaults.standard.object(forKey: "attention.enabled") as? Bool ?? true
    /// Main-thread mirror for the Settings toggle.
    private(set) var attentionCue: Bool = UserDefaults.standard.object(forKey: "attention.enabled") as? Bool ?? true
    private var immersionTarget: Float = 1
    private var immersionArmed = false
    private var immersionInvert = false        // DEBUG: swap the eyes→fade mapping (test with audio)
    private var lastEyesClosedState = false     // last committed eye state, so arm/invert re-evaluate now
    // Blink filter: eyes must stay closed this long before the scene fades in
    // (user-adjustable). Scene-in is what gates dwell/summaries — a blink that
    // happens to point at an agent must not open the letter.
    private var fadeDelaySecs = UserDefaults.standard.object(forKey: "immersion.fadeDelay") as? Double ?? 0.6
    private var pendingSceneIn = false
    private var eyesClosedAt = 0.0
    private var sceneInSince = 0.0 // 0 = the scene is not in
    /// Main-thread mirror for the Settings slider.
    private(set) var fadeDelay: Double = UserDefaults.standard.object(forKey: "immersion.fadeDelay") as? Double ?? 0.6

    // "An agent is waiting" attention cue: synthesized + spatialized INSIDE the main renderer
    // (antiphon-dsp AttentionCue), crossfaded against the scene by the same immersion value — so it is
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

    // drag audition: while a dot is being moved, the antiphon fades in even with
    // eyes open and the dragged agent pulses with a hot reverb send
    private var dragSeat = -1
    private var immersionHold = false
    /// Drone gate: how long after the last sign of life "working" keeps humming.
    private let droneHoldSecs = 45.0

    // The audition source: a dedicated extra source slot (index agents.count)
    // for onboarding cues and the fit loop. While it speaks it takes the room
    // over — agents duck against gAud and the eye fade is held open.
    // DOUBLE-BUFFERED: unlike every other one-shot, a new cue may interrupt a
    // playing one, so `q` stages into audStaged and bumps audTrig; the RENDER
    // thread adopts it at the trigger ack. Mutating audBuf from `q` mid-read
    // was a bounds trap on the IO thread (cal_left → cal_right crash).
    private var audSlot = 0
    private var audStaged: [Float] = []      // written on q, read by render at ack
    private var audStagedLoop = false
    private var audBuf: [Float] = []         // render-thread-owned after adoption
    private var audCur = -1
    private var audLoop = false
    private var audTrig = 0, audSeen = 0
    private var audTarget: Float = 0
    private var gAud: Float = 0

    // live bridge (antiphond): when connected, agents exist only as bound seats and
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
    private let dwellSecs = 1.0 // linger this long (counted only in-scene) to lock
    /// A given agent's dwell hum sounds at most this often.
    private let bloomCooldownSecs = 30.0

    // preallocated FFI scratch (no allocation in the render callback)
    private var inBufs: [UnsafeMutablePointer<Float>] = []
    private var inTable: UnsafeMutablePointer<UnsafePointer<Float>?>!
    private var srcArr: UnsafeMutablePointer<AntiphonSource>!

    // ---- the rest of the Mac (scratch/system-audio-tap.md) --------------------
    // One continuum: how far away is everything else the Mac plays? The tap
    // mutes it at the device and we re-emit — at unity while the eyes are open
    // (pass-through), pushed back + quieter as the scene comes in (deaden,
    // the default), or placed as a head-tracked ±30° virtual pair (spatialize,
    // the prototype). Scene coupling rides the renderer's own smoothed
    // immersion value, so the Mac recedes exactly as the room fades in.
    private var sysTapBox: AnyObject? // SystemAudioTap, gated on macOS 14.4
    private var sysPull: ((UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void)?
    private var sysOn = false          // render-thread gate (tap live)
    private var sysSpatial = false     // deaden (false) vs spatialize (true)
    private var sysDuckEnabled = true  // extra dip while an agent voice is live
    private var sysDuck: Float = 1     // smoothed on the render thread
    private var sysDist: Float = 2.2   // spatialize: virtual-pair distance (m)
    private var sysSlotL = 0, sysSlotR = 0
    private let sysDeadenLevel: Float = 0.22 // in-scene dry gain ≈ −13 dB
    private let sysGainSpatial: Float = 0.8  // placed-pair source gain
    /// The user-facing mode ("off" / "deaden" / "spatial"), persisted.
    @Published var sysMode = "deaden"

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
        // while the tap lives we are muting the user's Mac — restore it the
        // instant we quit rather than waiting for the OS to notice our death
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.shutdownSystemAudio() }
    }

    func setup() {
        guard !started, let res = Bundle.main.resourceURL else { return }
        let assetURL = res.appendingPathComponent("antiphon.antiphon")
        // +3: the audition source (onboarding cues, fit loop) + the system-audio
        // virtual pair (spatialize mode; slots unused unless the tap is live)
        guard let r = AntiphonRenderer(assetURL: assetURL, sampleRate: SAMPLE_RATE,
                                      maxSources: AGENTS.count + 3, maxBlock: maxBlock) else {
            print("[antiphon] failed to load renderer/asset"); return
        }
        renderer = r
        // the fit is personal — restore it (the slider lives in onboarding + settings)
        if UserDefaults.standard.object(forKey: "fit.freqScale") != nil {
            freqScale = UserDefaults.standard.double(forKey: "fit.freqScale")
        }
        DispatchQueue.main.async { self.hrtfName = (try? String(contentsOf: res.appendingPathComponent("hrtf.txt"))) ?? "" }

        // load voices + synthesize earcons
        let base = res.appendingPathComponent("audio")
        for (i, def) in AGENTS.enumerated() {
            let a = AgentRuntime(def: def, idx: i)
            let work = loadMono(base.appendingPathComponent("\(def.id).mp3")) ?? []
            a.clear = work
            a.whisper = work.isEmpty ? [] : whispered(work)
            a.summary = loadMono(base.appendingPathComponent("\(def.id)_done.mp3")) ?? []
            let pf = PING_FREQS[i % PING_FREQS.count]
            a.ping = makePing(pf)
            a.chime = makeChime(pf)
            a.bloom = makeBloom(pf)
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

        // preallocate FFI scratch (+3 = audition + system-audio pair)
        for _ in 0..<(n + 3) { inBufs.append(.allocate(capacity: maxBlock)) }
        inTable = .allocate(capacity: n + 3)
        srcArr = .allocate(capacity: n + 3)
        for (i, a) in agents.enumerated() {
            inTable[i] = UnsafePointer(inBufs[i])
            // fx/fy/fz zero = omnidirectional point source (legacy behaviour)
            srcArr[i] = AntiphonSource(x: a.posX, y: 0,
                                      z: a.posZ, gain: 1.0, send: voiceSend,
                                      fx: 0, fy: 0, fz: 0, directivity: 0, extent: 0)
        }
        audSlot = n
        inTable[audSlot] = UnsafePointer(inBufs[audSlot])
        srcArr[audSlot] = AntiphonSource(x: 0, y: 0, z: -radius, gain: 1.0, send: voiceSend,
                                        fx: 0, fy: 0, fz: 0, directivity: 0, extent: 0)
        // the system-audio virtual pair: a hi-fi on a shelf at ±30°, head-tracked.
        // Modest send — wideband music excites the reverb tail far harder than speech.
        sysSlotL = n + 1
        sysSlotR = n + 2
        for (slot, sign) in [(sysSlotL, Float(-1)), (sysSlotR, Float(1))] {
            inTable[slot] = UnsafePointer(inBufs[slot])
            srcArr[slot] = AntiphonSource(x: sign * sin(.pi / 6) * sysDist, y: 0,
                                         z: -cos(.pi / 6) * sysDist, gain: 0, send: voiceSend * 0.5,
                                         fx: 0, fy: 0, fz: 0, directivity: 0, extent: 0)
        }
        let ud0 = UserDefaults.standard
        if let m = ud0.string(forKey: "sysaudio.mode") { sysMode = m }
        if ud0.object(forKey: "sysaudio.dist") != nil { sysDist = Float(ud0.double(forKey: "sysaudio.dist")) }
        if ud0.object(forKey: "sysaudio.duck") != nil { sysDuckEnabled = ud0.bool(forKey: "sysaudio.duck") }
        sysSpatial = sysMode == "spatial"
        renderer.setRoom(roomIndex)
        // Muted until the user enters the room (openRoom). setup() now runs at app
        // LAUNCH so live-bridge state (binds, dones) accumulates correctly from
        // second zero; the intro click just turns the speakers on.
        renderer.setMasterGain(0.0)
        renderer.setFreqScale(Float(freqScale)) // push the default "fit" so it's applied from the first block

        // attention cue: synthesized + spatialized inside the MAIN renderer now (no second engine).
        renderer.setAttentionBuildMinutes(attnBuildMinutes)

        buildGraph()
        do { try engine.start() } catch { print("[antiphon] engine start: \(error)"); return }

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
            // the rest of the Mac joins the room (deaden by default) — created
            // here, not at launch, so onboarding never fires the TCC prompt
            self.startSysTap()
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
        // while the audition voice speaks, the agents step back
        let duck = 1 - 0.85 * gAud
        // mix each agent's active signals into its mono input buffer
        for (ai, a) in agents.enumerated() {
            if a.pingTrig != a.pingSeen { a.pingSeen = a.pingTrig; a.pingCur = 0 }
            if a.summaryTrig != a.summarySeen { a.summarySeen = a.summaryTrig; a.summaryCur = 0 }
            if a.chimeTrig != a.chimeSeen { a.chimeSeen = a.chimeTrig; a.chimeCur = 0 }
            if a.narrTrig != a.narrSeen { a.narrSeen = a.narrTrig; a.narrCur = 0 }
            if a.toolTrig != a.toolSeen { a.toolSeen = a.toolTrig; a.toolCur = 0 }
            let buf = inBufs[ai]
            let gc = a.gClear, gw = a.gWhisper, gp = a.gPing, gsum = a.gSummary, gn = a.gNarr
            let gb = a.gBloom, gd = a.gDrone, gpl = a.gPulse
            let humOn = gb > 0.001 // loop bed: advances only while audible
            for k in 0..<n {
                var s: Float = 0
                if !a.clear.isEmpty { s += a.clear[a.clearCur] * gc; a.clearCur = (a.clearCur + 1) % a.clear.count }
                if !a.whisper.isEmpty { s += a.whisper[a.whisperCur] * gw; a.whisperCur = (a.whisperCur + 1) % a.whisper.count }
                if a.pingCur >= 0 { s += a.ping[a.pingCur] * gp; a.pingCur += 1; if a.pingCur >= a.ping.count { a.pingCur = -1 } }
                // accept chime: spatialized through this agent's voice (was a centred, in-head one-shot)
                if a.chimeCur >= 0 { s += a.chime[a.chimeCur] * CHIME_GAIN; a.chimeCur += 1; if a.chimeCur >= a.chime.count { a.chimeCur = -1 } }
                if a.summaryCur >= 0 {
                    s += a.summary[a.summaryCur] * gsum; a.summaryCur += 1
                    if a.summaryCur >= a.summary.count { a.summaryCur = -1; a.summaryDone = true }
                }
                // live narration one-shot (bridge mode)
                if a.narrCur >= 0, !a.narr.isEmpty {
                    s += a.narr[a.narrCur] * gn; a.narrCur += 1
                    if a.narrCur >= a.narr.count { a.narrCur = -1 }
                }
                // talk-back dwell/lock hum (one continuous loop shaped by gBloom)
                if humOn, !a.bloom.isEmpty { s += a.bloom[a.bloomCur] * gb; a.bloomCur = (a.bloomCur + 1) % a.bloom.count }
                // chord identity: tool-call note (one-shot) + working drone (loop)
                if a.toolCur >= 0, !a.toolNote.isEmpty {
                    s += a.toolNote[a.toolCur]; a.toolCur += 1
                    if a.toolCur >= a.toolNote.count { a.toolCur = -1 }
                }
                if !a.drone.isEmpty { s += a.drone[a.droneCur] * gd; a.droneCur = (a.droneCur + 1) % a.drone.count }
                // drag audition pulse (reverb send is bumped while dragging)
                if !a.pulse.isEmpty { s += a.pulse[a.pulseCur] * gpl; a.pulseCur = (a.pulseCur + 1) % a.pulse.count }
                buf[k] = s * duck
            }
        }

        // the audition source (onboarding cues / fit loop)
        if started {
            if audTrig != audSeen { // adopt the staged cue HERE — only render touches audBuf
                audSeen = audTrig
                audBuf = audStaged
                audLoop = audStagedLoop
                audCur = 0
            }
            let abuf = inBufs[audSlot]
            let ga = gAud
            for k in 0..<n {
                var s: Float = 0
                if audCur >= 0, audCur < audBuf.count {
                    s = audBuf[audCur] * ga
                    audCur += 1
                    if audCur >= audBuf.count { audCur = audLoop ? 0 : -1 }
                }
                abuf[k] = s
            }
        }

        // pose: head yaw. forward = (sin orient, 0, -cos orient) => quaternion about +y of
        // -orient (the frame is pinned in CLAUDE.md). 6DoF head position is always fed below (true parallax).
        // Close the latency loop: this pose was captured at poseCaptureTime; it is reaching the
        // output now + the device output latency. (CACurrentMediaTime is mach-based, lock-free.)
        if poseCaptureTime > 0 {
            lastRenderLatencyMs = (CACurrentMediaTime() - poseCaptureTime) * 1000 + outputLatencyMs
        }

        // Immersion (eyes) fade + attention cue both live INSIDE the renderer now (per-source), so
        // we just forward the eyes target and the waiting-agent count before the single process()
        // call. The cue keeps building while eyes are closed (agents still waiting) — it's just
        // crossfaded to silence by the same immersion value, not reset.
        // A drag or voice audition holds the scene fully in regardless of eye state.
        renderer.setImmersion((immersionHold || audTarget > 0) ? 1 : immersionTarget)
        var waiting = 0
        for a in agents where a.state == .done && !a.snoozed { waiting += 1 } // agents wanting to summarize
        renderer.setAttentionAgents(attentionEnabled ? waiting : 0)

        // ---- the rest of the Mac: drain the tap and shape the continuum -------
        // The tap mutes the originals at the device, so whenever it's live WE are
        // the only path to the speakers — the pass-through below must run even
        // when the eye is off / the master is at zero, or the Mac goes silent.
        var sysImm: Float = 0
        if sysOn, started {
            sysPull?(inBufs[sysSlotL], inBufs[sysSlotR], n)
            // duck the Mac a little while an agent voice is actually speaking
            var voiceHot = false
            for a in agents where a.gClear > 0.05 || a.gSummary > 0.05 || a.gNarr > 0.05 {
                voiceHot = true
                break
            }
            let duckT: Float = (sysDuckEnabled && voiceHot) ? 0.3 : 1
            sysDuck += (duckT - sysDuck) * 0.04
            // scene coupling: armed + watching → the renderer's own smoothed fade
            sysImm = (immersionArmed && watchingInternal) ? renderer.immersion() : 0
            if sysSpatial {
                // in-scene: the placed pair (the engine multiplies by immersion
                // itself, so gain here is the full-scene value)
                let g = sysGainSpatial * sysDuck
                srcArr[sysSlotL].gain = g
                srcArr[sysSlotR].gain = g
            }
        }

        let h = 0.5 * orient
        // 6DoF is always on: feed the (filtered, neutral-relative, ±1 m-clamped) head position so
        // leaning/shifting gives true motion parallax — the strongest externalization cue.
        var pose = AntiphonPose(px: Float(headX), py: Float(headY), pz: Float(headZ),
                               qw: Float(cos(h)), qx: 0, qy: Float(-sin(h)), qz: 0)
        let nSrc = agents.count + 1 + (sysOn && sysSpatial ? 2 : 0)
        renderer.process(pose: &pose, sources: UnsafePointer(srcArr), n: nSrc,
                         inputs: UnsafePointer(inTable), outL: outL, outR: outR, frames: n)
        // Scene faded + cue crossfaded per-source inside process(); accept chime is mixed into its
        // agent's voice above (spatialized). Nothing to post-multiply.

        // ---- system-audio dry re-emit (post-mix: bypasses master, by design) ---
        if sysOn, started {
            // deaden: unity out of scene → pushed back + quieter as the room
            // fades in. spatialize: dry crossfades OUT as the placed pair (in
            // the renderer, already immersion-scaled) takes over.
            let gDry: Float = sysSpatial
                ? (1 - sysImm)
                : (1 - sysImm) + sysImm * sysDeadenLevel * sysDuck
            if gDry > 0.0005 {
                let Lb = inBufs[sysSlotL], Rb = inBufs[sysSlotR]
                for k in 0..<n {
                    outL[k] += Lb[k] * gDry
                    outR[k] += Rb[k] * gDry
                }
            }
        }
    }

    // MARK: the rest of the Mac (system-audio tap lifecycle)

    /// Mode: "off", "deaden" (default — the Mac steps back when the scene is in),
    /// or "spatial" (prototype — a head-tracked virtual pair in the room).
    func setSystemAudio(mode: String) {
        UserDefaults.standard.set(mode, forKey: "sysaudio.mode")
        DispatchQueue.main.async { self.sysMode = mode }
        q.async {
            self.sysSpatial = mode == "spatial"
            if mode == "off" {
                self.stopSysTap()
            } else if self.roomOpened {
                self.startSysTap()
            }
        }
    }

    func setSystemAudioDistance(_ d: Double) {
        UserDefaults.standard.set(d, forKey: "sysaudio.dist")
        q.async {
            self.sysDist = Float(max(1.0, min(3.0, d)))
            guard self.started else { return }
            for (slot, sign) in [(self.sysSlotL, Float(-1)), (self.sysSlotR, Float(1))] {
                self.srcArr[slot].x = sign * sin(.pi / 6) * self.sysDist
                self.srcArr[slot].z = -cos(.pi / 6) * self.sysDist
            }
        }
    }

    func setSystemAudioDuck(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "sysaudio.duck")
        q.async { self.sysDuckEnabled = on }
    }

    /// Creates the tap (first time fires the TCC "System Audio Recording"
    /// prompt). Called when the room opens and on mode changes; `q` only.
    private func startSysTap() {
        guard sysTapBox == nil, sysMode != "off", started else { return }
        // dev harness instances must never grab the global tap — it would mute
        // the Mac (including a real Antiphon instance) out from under the user
        if ProcessInfo.processInfo.environment["ANTIPHON_DEV"]?.contains("notap") == true { return }
        if #available(macOS 14.4, *) {
            guard let tap = SystemAudioTap() else {
                print("[antiphon] system tap unavailable (permission or OS)")
                return
            }
            sysTapBox = tap
            sysDuck = 1
            sysPull = { [weak tap] l, r, n in tap?.pull(l, r, n) }
            sysOn = true
        }
    }

    private func stopSysTap() {
        sysOn = false
        sysPull = nil
        if #available(macOS 14.4, *), let tap = sysTapBox as? SystemAudioTap {
            tap.teardown()
        }
        sysTapBox = nil
    }

    /// Quit-path teardown — un-mutes the Mac immediately rather than waiting
    /// for the OS to notice our death (taps fail open either way).
    func shutdownSystemAudio() {
        q.sync { self.stopSysTap() }
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
            self.pendingSceneIn = false
            self.sceneInSince = self.immersionTarget == 1 && on ? self.now() : 0
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
            if self.immersionArmed {
                if self.immersionTargetFor(closed) == 1 {
                    // entering: hold for the blink filter — tick() completes it
                    self.pendingSceneIn = true
                    self.eyesClosedAt = self.now()
                    if self.fadeDelaySecs <= 0.01 { self.enterScene(at: self.now()) }
                } else {
                    // leaving is always immediate
                    self.pendingSceneIn = false
                    self.sceneInSince = 0
                    self.immersionTarget = 0
                }
            }
            if self.lockedSeat >= 0 { // lantern (closed) ↔ letter (open)
                DispatchQueue.main.async { self.talkback.setEyesClosed(closed) }
            }
        }
    }

    /// Runs on `q`: the blink filter elapsed — bring the room in.
    private func enterScene(at t: Double) {
        pendingSceneIn = false
        immersionTarget = 1
        sceneInSince = t
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
        q.async { self.renderer?.setRoom(i); self.roomIndexQ = i }
        DispatchQueue.main.async { self.roomIndex = i }
    }
    /// 0 = parametric FDN tail, 1 = measured BRIR tail (only affects rooms that have a BRIR).
    func setReverbBlend(_ b: Double) {
        q.async { self.renderer?.setReverbBlend(Float(b)) }
        DispatchQueue.main.async { self.reverbBlend = b }
    }
    /// The waiting cue (eyes-open bloom): on/off.
    func setAttentionCue(_ on: Bool) {
        attentionCue = on
        UserDefaults.standard.set(on, forKey: "attention.enabled")
        q.async { self.attentionEnabled = on }
    }

    /// Blink filter: seconds of closed eyes before the room fades in.
    func setFadeDelay(_ secs: Double) {
        let v = max(0, min(3, secs))
        fadeDelay = v
        UserDefaults.standard.set(v, forKey: "immersion.fadeDelay")
        q.async { self.fadeDelaySecs = v }
    }

    /// HRTF "fit": frequency-scale the HRTF to better match the listener's pinna (front-back cue).
    /// Personal — persisted, set during onboarding and adjustable in Settings.
    func setFreqScale(_ s: Double) {
        q.async { self.renderer?.setFreqScale(Float(s)) }
        UserDefaults.standard.set(s, forKey: "fit.freqScale")
        DispatchQueue.main.async { self.freqScale = s }
    }

    // MARK: onboarding / fit audition (the dedicated extra source)

    /// Speak a bundled onboarding cue (onboarding/<name>_<lang>.mp3, falling
    /// back to English) from `bearingDeg`. While it plays, agents duck and the
    /// eye fade holds open. `loop` repeats with a breath of silence (the fit
    /// loop); one-shots just end.
    /// Play raw audio (the settings' live voice audition) through the audition
    /// slot: same ducking, same immersion hold, self-releasing one-shot.
    func auditionPlay(data: Data, ext: String, bearingDeg: Double = 0) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-audition.\(ext)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do { try data.write(to: url) } catch { return }
            guard let samples = loadMono(url), !samples.isEmpty else { return }
            self.q.async {
                guard self.started else { return }
                let b = rad(bearingDeg)
                self.srcArr[self.audSlot].x = Float(sin(b)) * self.radius
                self.srcArr[self.audSlot].z = Float(-cos(b)) * self.radius
                self.audStaged = samples
                self.audStagedLoop = false
                self.audTarget = 1
                self.audTrig += 1
            }
        }
    }

    func onboardPlay(_ name: String, loop: Bool = false, bearingDeg: Double = 0) {
        let lang = I18n.shared.lang.rawValue
        guard let res = Bundle.main.resourceURL else { return }
        var url = res.appendingPathComponent("onboarding/\(name)_\(lang).mp3")
        if !FileManager.default.fileExists(atPath: url.path) {
            url = res.appendingPathComponent("onboarding/\(name)_en.mp3")
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self, var samples = loadMono(url), !samples.isEmpty else { return }
            if loop { samples.append(contentsOf: [Float](repeating: 0, count: Int(SAMPLE_RATE * 1.1))) }
            self.q.async {
                guard self.started else { return }
                let b = rad(bearingDeg)
                self.srcArr[self.audSlot].x = Float(sin(b)) * self.radius
                self.srcArr[self.audSlot].z = Float(-cos(b)) * self.radius
                self.audStaged = samples
                self.audStagedLoop = loop
                self.audTarget = 1
                self.audTrig += 1 // render adopts the staged buffer at the ack
            }
        }
    }

    /// Let the audition voice go (fades out; a finished one-shot is a no-op).
    func onboardStop() {
        q.async {
            self.audTarget = 0
            self.audLoop = false
        }
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

    /// A dot picked up on the radar: hold the antiphon audible (even with eyes
    /// open) and pulse the agent so its place is felt. The pulse stays as dry
    /// as the voice — the direct path carries the position.
    func dragBegan(_ seat: Int) {
        q.async {
            guard self.agents.indices.contains(seat) else { return }
            self.dragSeat = seat
            self.immersionHold = true
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
            let a = self.agents[seat]
            let ud = UserDefaults.standard
            ud.set(Double(a.posX), forKey: "seatpos.x.\(seat)")
            ud.set(Double(a.posZ), forKey: "seatpos.z.\(seat)")
            ud.set(true, forKey: "seatpos.set.\(seat)")
        }
    }

    /// Runs on `q`. Too close is deafening (keep a 0.45 m bubble); beyond the
    /// room's walls the reverb model no longer matches and voices go flat, so
    /// the reverb chamber itself is the outer bound.
    private func place(seat: Int, x: Double, z: Double) {
        guard agents.indices.contains(seat) else { return }
        var wx = x, wz = z
        if let dims = renderer?.roomDims(roomIndexQ) {
            let margin: Double = 0.35 // off the walls — image sources misbehave at 0
            let hx = max(0.6, Double(dims.x) / 2 - margin)
            let hz = max(0.6, Double(dims.z) / 2 - margin)
            wx = min(max(wx, -hx), hx)
            wz = min(max(wz, -hz), hz)
        }
        let d = max(sqrt(wx * wx + wz * wz), 1e-6)
        let clamped = max(d, 0.45)
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

    // MARK: live bridge (antiphond /stream)

    /// First hello (or reconnect) → enter live mode: hide everyone until seats bind,
    /// stop the demo's auto-finish, drop the canned loops. Disconnect keeps live mode
    /// (agents freeze; the bridge retries in the background). Runs on `q`.
    private func applyLiveMode() {
        autoFinishInternal = false
        for (i, a) in agents.enumerated() {
            a.present = boundSeats.contains(i)
            a.state = .working
            a.clear = []; a.whisper = [] // live agents speak narration, not loops
            a.gClear = 0; a.gWhisper = 0; a.gPing = 0
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
                    title: String? = nil, input: String? = nil,
                    repo: String? = nil, cwd: String? = nil, branch: String? = nil) {
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
            if let repo, !repo.isEmpty { m.repo = repo }
            if let cwd, !cwd.isEmpty { m.cwd = cwd }
            if let branch { m.branch = branch } // "" clears (branch switched away)
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
            if lines.count > 24 { lines.removeFirst(lines.count - 24) } // a conversation, not a marquee
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
                // the antiphon: keep the agent in the room, pinging, until it's heard.
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

        // blink filter: the eyes have stayed closed long enough — scene in
        if pendingSceneIn, immersionArmed, lastEyesClosedState,
           t - eyesClosedAt >= fadeDelaySecs { enterScene(at: t) }

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

        // audition voice fade (onboarding cues / fit loop). A finished one-shot
        // cue lets go of the room by itself — otherwise the immersion hold and
        // the agent duck stay pinned after calibration. (Loops hold until
        // onboardStop; audTrig==audSeen guards a not-yet-started replacement.)
        if audTarget > 0, !audLoop, audCur == -1, audTrig == audSeen { audTarget = 0 }
        gAud += (audTarget - gAud) * 0.12

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
            default: break
            }
        }

        if autoFinishInternal, t >= nextAuto {
            nextAuto = t + AUTO_FINISH_MIN + Double.random(in: 0...(AUTO_FINISH_MAX - AUTO_FINISH_MIN))
            finishRandom()
        }

        let fi = facedIndex()
        // Summaries are an eyes-closed moment once the fade is armed: an
        // eyes-open glance must not start one into a silent scene (it would
        // be consumed unheard). Unarmed (demo/debug) keeps the old behavior.
        let listening = !immersionArmed || (lastEyesClosedState && sceneInSince > 0)
        if fi >= 0, listening, lookGate > 0.6, agents[fi].state == .done {
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
        // dwell exists only INSIDE the scene: the clock starts after the blink
        // filter has brought the room in, never during an eyes-open glance
        let inScene = lastEyesClosedState && (!immersionArmed || sceneInSince > 0)
        if inScene {
            if fi != cooldownSeat { cooldownSeat = -1 }
            if fi >= 0, fi != lockedSeat, fi != cooldownSeat {
                if dwellSeat != fi {
                    dwellSeat = fi
                    dwellStart = t
                    let a = agents[fi]
                    a.bloomLive = t - a.lastBloomAt >= bloomCooldownSecs
                    if a.bloomLive { a.lastBloomAt = t }
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
        // One continuous hum per agent: builds in while dwelt on, leans up for
        // a beat at the lock, releases gently — the shape is all in this gain.
        // Cooled-down agents dwell/lock silently (bloomLive gates the sound).
        for (i, a) in agents.enumerated() {
            var target: Float = (i == dwellSeat && a.bloomLive) ? 0.7 : 0
            if t - a.crestAt < 0.45 { target = 1.0 } // the crest: same hum, leaning in
            let rate: Float = target > a.gBloom ? 0.05 : 0.03 // slow build, slower release
            a.gBloom += (target - a.gBloom) * rate
        }
    }

    private func lock(seat: Int) {
        lockedSeat = seat
        if agents.indices.contains(seat), agents[seat].bloomLive {
            agents[seat].crestAt = now() // the crest belongs to an audible dwell
        }
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
            repo: meta?.repo ?? "",
            cwd: meta?.cwd ?? "",
            branch: meta?.branch ?? "",
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
            let seat = self.lockedSeat
            if self.liveBridge {
                self.bridge?.sendSay(seat: seat, text: text)
            } else {
                NSLog("[talkback] (demo) say seat=%d: %@", seat, text)
            }
            // your side of the conversation belongs in the transcript too
            var lines = self.seatLines[seat] ?? []
            lines.append(TalkbackLine(kind: "you", text: text, at: Date().timeIntervalSince1970))
            if lines.count > 24 { lines.removeFirst(lines.count - 24) }
            self.seatLines[seat] = lines
            if self.lockedSeat == seat { self.pushTalkback(present: false) }
        }
    }

    /// Dev harness (ANTIPHON_DEV=talkback): lock onto a fake agent with canned data so
    /// the panel's focus mechanics are testable with no daemon, camera, or agent.
    /// Presents eyes-open, so it also exercises the empty-field grace auto-dismiss.
    func talkbackHarness() {
        q.async {
            let now = Date().timeIntervalSince1970
            self.seatMeta[2] = TalkbackSeatMeta(
                name: "wren", kind: "claude-code",
                title: "wiring the reconnect path in BridgeClient",
                repo: "cfoust/antiphon", cwd: NSHomeDirectory() + "/Developer/cfoust/chamber",
                branch: "fix/room-polish", input: "tmux")
            self.seatLines[2] = [
                TalkbackLine(kind: "task", text: "Wiring the reconnect path in BridgeClient", at: now - 240),
                TalkbackLine(kind: "progress", text: "Backoff works; adding the respawn guard so a dead daemon comes back without dropping any narration frames on the floor", at: now - 70),
                TalkbackLine(kind: "you", text: "Keep the backoff under a second — the room going quiet is worse than a little churn.", at: now - 40),
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
                continue
            }
            let faced = i == facedIdx
            let front = (cos(angdiff(a.bearing, orient)) + 1) / 2
            var clear: Float = 0, whisper: Float = 0
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
            default: break // .heard rests silently until it recycles
            }
            a.gClear += (clear - a.gClear) * 0.15
            a.gWhisper += (whisper - a.gWhisper) * 0.15
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
        a.state = .working; a.heardAt = 0; a.gPing = 0
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
                    pingAge: $0.lastPingWall > 0 ? t - $0.lastPingWall : 99,
                    title: seatMeta[$0.idx]?.title ?? "",
                    lastLine: seatLines[$0.idx]?.last?.text ?? "",
                    lastAt: seatLines[$0.idx]?.last?.at ?? 0)
        }
        let o = orient, g = lookGate
        let hp = SIMD3(headX, headY, headZ)
        let lat = lastRenderLatencyMs
        let imm = Double(renderer?.immersion() ?? 1) // smoothed value from the engine; benign race — fine for a debug readout
        let list = buildAgentList(at: t)
        let listChanged = list != lastAgentList
        if listChanged { lastAgentList = list }
        DispatchQueue.main.async {
            // every @Published set fires objectWillChange — at 30 Hz that re-rendered
            // every observing view continuously (janky settings scroll). Guard each.
            let vmsChanged = vms.count != self.snapshot.count
                || zip(vms, self.snapshot).contains { a, b in
                    a.id != b.id || a.state != b.state
                        || a.lastLine != b.lastLine || a.title != b.title
                        || abs(a.x - b.x) > 0.0005 || abs(a.z - b.z) > 0.0005
                        || (a.pingAge < 1.2 || b.pingAge < 1.2) && a.pingAge != b.pingAge
                }
            if vmsChanged { self.snapshot = vms }
            if abs(self.orientRad - o) > 0.0015 { self.orientRad = o }
            if abs(self.lookGatePub - g) > 0.004 { self.lookGatePub = g }
            if self.facedPub != facedIdx { self.facedPub = facedIdx }
            let hpDelta = max(abs(self.headPos.x - hp.x), max(abs(self.headPos.y - hp.y), abs(self.headPos.z - hp.z)))
            if hpDelta > 0.002 { self.headPos = hp }
            if abs(self.latencyMs - lat) > 0.5 { self.latencyMs = lat }
            if abs(self.immersionLevel - imm) > 0.004 { self.immersionLevel = imm }
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
                repo: meta?.repo ?? "",
                cwd: meta?.cwd ?? "",
                branch: meta?.branch ?? "",
                hex: a.def.hex,
                status: status,
                lastLine: last?.text ?? "",
                lastKind: last?.kind ?? "",
                waiting: a.state == .done,
                snoozed: a.snoozed)
        }
    }
}
