import SwiftUI

@main
struct ChamberAppMain: App {
    var body: some Scene {
        WindowGroup("Chamber") { ContentView() }
            .defaultSize(width: 720, height: 980)
    }
}

/// Mirrors the web experience: an intro gate, a voice-guided two-point calibration, then a
/// full radar. (The web app and this share the same flow + radar so they feel identical.)
struct ContentView: View {
    @StateObject private var tracker = FaceTracker()
    @StateObject private var engine = ChamberEngine()
    @State private var enabled = false
    @State private var live = false
    @State private var showDebug = false
    @State private var calArrow = ""
    @State private var calText = ""
    @State private var immersionEnabled = true // eyes-closed → scene fills in; user-toggleable below
    private let rooms = ["dry", "room (FDN)", "hall (FDN)", "cathedral (FDN)", "room (BRIR)", "hall (BRIR)"]

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.047, blue: 0.063).ignoresSafeArea()

            if live {
                VStack(spacing: 14) {
                    Radar(engine: engine)
                    HStack(spacing: 16) {
                        Picker("", selection: Binding(get: { engine.roomIndex }, set: { engine.setRoom($0) })) {
                            ForEach(rooms.indices, id: \.self) { Text(rooms[$0]).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                        Button("Recalibrate") { runCalibration() }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    // BRIR rooms can blend their measured tail with the parametric FDN tail.
                    if engine.roomIndex >= 4 {
                        HStack(spacing: 10) {
                            Text("FDN").font(.caption2).foregroundStyle(.secondary)
                            Slider(value: Binding(get: { engine.reverbBlend },
                                                  set: { engine.setReverbBlend($0) }), in: 0...1)
                                .frame(width: 170)
                            Text("BRIR").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    // HRTF "fit": dial until a source straight ahead sits OUT in front at ear level.
                    HStack(spacing: 10) {
                        Text("Fit").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { engine.freqScale },
                                              set: { engine.setFreqScale($0) }), in: 0.7...2.2)
                            .frame(width: 200)
                        Text(String(format: "%.2f", engine.freqScale))
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                    Text("Turn to face an agent to hear it open up · look down to whisper all")
                        .font(.caption2).foregroundStyle(.tertiary)
                    // Eyes-closed immersion fade: close your eyes and the scene fills in; open them and
                    // it fades to silence. User-toggleable — off holds full audio regardless of eyes.
                    Toggle(isOn: $immersionEnabled) {
                        Text("Immersion fade · close eyes → scene fills in")
                    }
                    .toggleStyle(.switch).font(.caption).frame(width: 320)
                    .onChange(of: immersionEnabled) { on in engine.setImmersionArmed(on) }
                    Text(String(format: "eyes %@ · openness %.2f · immersion %.2f%@",
                                tracker.eyesClosed ? "closed" : "open", tracker.eyeOpenness,
                                engine.immersionLevel, tracker.eyesCalibratedPub ? "" : " · calibrating…"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(tracker.eyesClosed ? Color.green : Color.secondary)
                }
                .padding(20)
            }

            // calibration overlay
            if !calText.isEmpty {
                VStack(spacing: 10) {
                    Text(calArrow).font(.system(size: 76, weight: .thin))
                    Text(calText).font(.title3)
                }
                .foregroundStyle(.white)
                .padding(40)
                .background(.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if showDebug {
                TrackingDebugView(tracker: tracker, engine: engine) { showDebug = false }
            }

            // intro gate
            if !live && calText.isEmpty && !showDebug {
                introCard
            }
        }
        .frame(minWidth: 660, minHeight: 700)
        .preferredColorScheme(.dark)
    }

    private var introCard: some View {
        VStack(spacing: 18) {
            Text("Agent Chamber").font(.system(size: 28, weight: .bold))
            Text("A team of agents, working around you in space. You hear them murmur as they work, and chime when they finish — turn to face one to listen.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                req("🎧", "Headphones required", "The audio is positioned in 3D — it only works over headphones.")
                req("📷", "Camera access", "Turn your head to face agents. Video never leaves your device.")
            }
            if !enabled {
                Button("Enable camera & continue") { enable() }.buttonStyle(.borderedProminent)
            } else {
                // Skip the two-point flow if a calibration was restored from a previous session.
                Button(tracker.hasSavedCalibration ? "Start" : "Calibrate & start") {
                    if tracker.hasSavedCalibration { engine.setImmersionArmed(immersionEnabled); live = true } else { runCalibration() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tracker.faceFound)
                Text(tracker.faceFound ? (tracker.hasSavedCalibration ? "Calibration restored" : "Head tracking ready")
                                       : "Looking for your face…")
                    .font(.caption).foregroundStyle(tracker.faceFound ? .green : .secondary)
                if tracker.hasSavedCalibration {
                    Button("Recalibrate") { runCalibration() }
                        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                }
                Button("Debug tracking →") { showDebug = true }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
            }
            if !engine.hrtfName.isEmpty {
                Text(engine.hrtfName).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(28).frame(width: 400)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08)))
    }

    private func req(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(icon).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func enable() {
        engine.setup()
        // No sign flip: the two-point calibration below resolves the camera's yaw direction
        // (the uncalibrated default is what was inverted). 6DoF position from the bbox estimate.
        tracker.onOrient = { [weak engine] d in engine?.setOrient(deg: d) }
        tracker.onGate = { [weak engine] g in engine?.setLookGate(g) }
        tracker.onPosition = { [weak engine] x, y, z in engine?.setPosition(x, y, z) }
        tracker.onPoseStamp = { [weak engine] t in engine?.setPoseStamp(t) }
        // Eyes closed → fade the binaural scene IN; eyes open → fade OUT. The engine's envelope
        // stays at full until armImmersion() (called when the live experience starts below), so the
        // intro/calibration audio is audible even though the detector is already running.
        tracker.onEyesClosed = { [weak engine] closed in engine?.setEyesClosed(closed) }
        tracker.start()
        enabled = true
    }

    private func startDebug() { showDebug = true }

    /// Voice-less two-point calibration: look fully left, then fully right.
    private func runCalibration() {
        Task { @MainActor in
            calArrow = "←"; calText = "Look all the way left… and hold"
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            let yl = tracker.yaw, pl = tracker.pitch
            calArrow = "→"; calText = "Now all the way right… and hold"
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            let yr = tracker.yaw, pr = tracker.pitch
            tracker.calibrate(yawLeftRad: yl, yawRightRad: yr, neutralPitchRad: (pl + pr) / 2)
            tracker.resetNeutral() // capture the 6DoF neutral at a comfortable resting pose
            tracker.persistCalibration() // remember it so we don't recalibrate next launch
            calArrow = "✓"; calText = "Calibrated"
            try? await Task.sleep(nanoseconds: 900_000_000)
            calText = ""; calArrow = ""
            engine.setImmersionArmed(immersionEnabled) // arm the eyes-closed immersion fade (if enabled) as the live experience begins
            live = true
        }
    }
}

/// Live PnP-tracking diagnostics — record this screen while moving your head so the
/// landmark detection + solver output can be validated.
struct TrackingDebugView: View {
    @ObservedObject var tracker: FaceTracker
    @ObservedObject var engine: ChamberEngine
    let back: () -> Void
    private let labels = ["nose", "chin", "L eye", "R eye", "mouth L", "mouth R"]
    private let colors: [Color] = [.red, .orange, .blue, .cyan, .green, .yellow]
    @State private var mirror = false   // overlay x matches the preview as-is; toggle if it flips
    @State private var testFade = true  // arm the immersion fade here (normally only armed when live)
    @State private var invert = false   // invert eyes→fade so eyes-OPEN fades in (test with audio)

    var body: some View {
        ScrollView {
        VStack(spacing: 12) {
            HStack {
                Button("← Back") { back() }.buttonStyle(.borderless)
                Spacer()
                Text("PnP tracking debug").font(.headline)
                Spacer()
                Text(String(format: "%.0f Hz", tracker.hz)).font(.caption).foregroundStyle(.secondary)
            }
            // centered camera with the landmarks drawn directly on top of the video
            ZStack {
                CameraPreview(session: tracker.session)
                Canvas { ctx, size in
                    let W = size.width, H = size.height
                    func map(_ p: CGPoint) -> CGPoint {
                        CGPoint(x: (mirror ? (1 - p.x) : p.x) * W, y: (1 - p.y) * H) // y-up img → y-down view
                    }
                    // eye-contour points (small): green when open, red when held-closed — so you
                    // can watch the actual eyelid landmarks the closure detector is reading.
                    let eyeColor: Color = tracker.eyesClosed ? .red : .green
                    for p in tracker.leftEye01 + tracker.rightEye01 {
                        let q = map(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4)),
                                 with: .color(eyeColor))
                    }
                    // the 6 PnP model landmarks (large, legend-colored)
                    for (i, p) in tracker.landmarks01.enumerated() {
                        let q = map(p)
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 5, y: q.y - 5, width: 10, height: 10)),
                                 with: .color(colors[i % colors.count]))
                    }
                }
            }
            .aspectRatio(tracker.imageAspect, contentMode: .fit)
            .frame(maxWidth: 460, maxHeight: 345)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Toggle("mirror", isOn: $mirror).toggleStyle(.button).font(.caption2)
                    .padding(6).background(.black.opacity(0.4)).clipShape(Capsule()).padding(8)
            }
            HStack(spacing: 12) {
                ForEach(0..<labels.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(colors[i]).frame(width: 8, height: 8)
                        Text(labels[i]).font(.caption2)
                    }
                }
                Text("· eye contour (green=open/red=closed)").font(.caption2).foregroundStyle(.tertiary)
            }.foregroundStyle(.secondary)

            Text(tracker.debug.isEmpty ? "waiting for a face…" : tracker.debug)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))

            Text(String(format: "smoothed → orient %+.0f°   pitch %+.0f°   roll %+.0f°",
                        deg(tracker.yaw), deg(tracker.pitch), deg(tracker.roll)))
                .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)

            // latency oracle (plan 07): sensor = capture+Vision+PnP; total = motion→sound.
            Text(String(format: "latency → sensor %.0f ms   motion→sound %.0f ms  (target < 60)",
                        tracker.sensorLatencyMs, engine.latencyMs))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(engine.latencyMs > 0 && engine.latencyMs < 60 ? .green : .orange)

            // eye-closure detector → immersion fade
            EyeClosureDebug(tracker: tracker, engine: engine)

            // rolling openness signal (dashed lines = the close/open hysteresis thresholds below)
            OpennessGraph(tracker: tracker)

            // tune the hysteresis band — both dashed lines on the graph move with these
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("close ≤").font(.caption2.monospaced()).foregroundStyle(.red)
                    Slider(value: Binding(
                        get: { tracker.eyeCloseThreshold },
                        set: { tracker.setEyeThresholds(close: $0, open: max($0 + 0.05, tracker.eyeOpenThreshold)) }),
                        in: 0.05...0.90)
                    Text(String(format: "%.2f", tracker.eyeCloseThreshold))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("open ≥").font(.caption2.monospaced()).foregroundStyle(.green)
                    Slider(value: Binding(
                        get: { tracker.eyeOpenThreshold },
                        set: { tracker.setEyeThresholds(close: min(tracker.eyeCloseThreshold, $0 - 0.05), open: $0) }),
                        in: 0.10...0.95)
                    Text(String(format: "%.2f", tracker.eyeOpenThreshold))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                Text("openness = mean of both eyes · between the lines = hold current state (anti-flicker)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(10).background(.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))

            // test the fade right here (normally it's only armed once the live experience starts)
            HStack(spacing: 18) {
                Toggle("fade in debug", isOn: $testFade)
                    .onChange(of: testFade) { on in engine.setImmersionArmed(on) }
                Toggle("invert (eyes-open → in)", isOn: $invert)
                    .onChange(of: invert) { on in engine.setImmersionInvert(on) }
                Spacer()
                Text(String(format: "immersion %.2f", engine.immersionLevel))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .toggleStyle(.switch).font(.caption)
            .padding(10).background(.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Move your head to check tracking; close your eyes to check the fade. “fade in debug” arms it here; “invert” lets you test with your eyes open.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 620)
        }
        .background(Color(red: 0.04, green: 0.047, blue: 0.063))
        // arm the fade on entry so debug mode fades with your eyes by default (onChange won't fire
        // for the initial toggle state); restore normal full-audio on exit.
        .onAppear { engine.setImmersionArmed(true) }
        .onDisappear { engine.setImmersionArmed(false); engine.setImmersionInvert(false) }
    }
}

/// Live eye-closure detector readout: is it seeing your eyes closed, and is that fading the scene?
/// Openness is the normalized [0,1] signal; the ticks are the 0.35 (close) / 0.55 (open) hysteresis
/// band. `immersion gain` is the host envelope actually multiplying the audio (1 = full, 0 = silent).
struct EyeClosureDebug: View {
    @ObservedObject var tracker: FaceTracker
    @ObservedObject var engine: ChamberEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("EYES").font(.callout.monospaced().bold()).foregroundStyle(.secondary)
                if !tracker.eyesCalibratedPub {
                    Text("calibrating open-eye baseline… hold eyes open ~1 s")
                        .foregroundStyle(.orange)
                } else if tracker.eyesClosed {
                    Text("CLOSED → scene fades IN").foregroundStyle(.green).bold()
                } else {
                    Text("OPEN → scene fades OUT").foregroundStyle(.secondary)
                }
                if !tracker.eyeReliable { Text("· held (turned)").foregroundStyle(.yellow) }
                Spacer()
            }.font(.callout.monospaced())

            Text(String(format: "openness %.2f   raw %.4f   immersion gain %.2f   armed %@%@",
                        tracker.eyeOpenness, tracker.eyeRaw, engine.immersionLevel,
                        engine.immersionArmedPub ? "yes" : "no",
                        engine.immersionInvertPub ? "   (inverted)" : ""))
                .font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Rolling time-series of the normalized eye-openness signal, newest at the right. Dashed lines mark
/// the 0.35 (close) and 0.55 (open) hysteresis thresholds; the trace/dot goes green while held-closed.
struct OpennessGraph: View {
    @ObservedObject var tracker: FaceTracker
    @State private var samples: [Double] = []
    private let maxN = 240

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // hysteresis threshold lines (track the sliders)
            for (t, col) in [(tracker.eyeCloseThreshold, Color.red), (tracker.eyeOpenThreshold, Color.green)] {
                let y = h * (1 - CGFloat(t))
                ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y)) },
                           with: .color(col.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            guard samples.count > 1 else { return }
            let dx = w / CGFloat(maxN - 1)
            let x0 = w - CGFloat(samples.count - 1) * dx // right-align newest
            var path = Path()
            for (i, o) in samples.enumerated() {
                let pt = CGPoint(x: x0 + CGFloat(i) * dx, y: h * (1 - CGFloat(max(0, min(1, o)))))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            let closed = tracker.eyesClosed
            ctx.stroke(path, with: .color(closed ? .green : .teal), lineWidth: 1.5)
            if let last = samples.last {
                let pt = CGPoint(x: x0 + CGFloat(samples.count - 1) * dx, y: h * (1 - CGFloat(last)))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)),
                         with: .color(closed ? .green : .teal))
            }
        }
        .frame(height: 90)
        .frame(maxWidth: .infinity)
        .background(.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            Text("openness (1 = open)").font(.caption2).foregroundStyle(.tertiary).padding(6)
        }
        .onReceive(tracker.$eyeOpenness) { o in
            samples.append(o)
            if samples.count > maxN { samples.removeFirst(samples.count - maxN) }
        }
    }
}
