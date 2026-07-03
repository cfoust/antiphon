import SwiftUI

@main
struct ChamberAppMain: App {
    @StateObject private var tracker = FaceTracker()
    @StateObject private var engine = ChamberEngine()

    var body: some Scene {
        // Full-bleed: the radar IS the window — traffic lights float over it.
        WindowGroup("Chamber") { ContentView(tracker: tracker, engine: engine) }
            .defaultSize(width: 1080, height: 780)
            .windowStyle(.hiddenTitleBar)
    }
}

/// The main window: an intro gate, a two-point calibration, then the chamber —
/// a full-bleed top-down visualization with the residents' list on the right.
struct ContentView: View {
    @ObservedObject var tracker: FaceTracker
    @ObservedObject var engine: ChamberEngine
    @State private var showSettings = false
    @State private var enabled = false
    @State private var live = false
    @State private var showDebug = false
    /// Onboarding: camera choice → voice-guided calibration → fit. `.none` =
    /// intro (pre-live) or the chamber itself (live). Recalibrate re-enters
    /// `.calibrate` alone.
    private enum OnboardStep { case none, camera, calibrate, fit }
    @State private var step: OnboardStep = .none
    @State private var immersionEnabled = true // eyes-closed → scene fills in (toggle in Settings)
    @State private var menuBar = MenuBarController()
    @ObservedObject private var i18n = I18n.shared

    var body: some View {
        ZStack {
            // asleep = the room grays out (camera off, silent)
            (engine.watching
                ? Color(red: 0.04, green: 0.047, blue: 0.063)
                : Color(white: 0.18))
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.35), value: engine.watching)

            if live {
                RadarView(engine: engine).ignoresSafeArea()

                // right rail: eye + gear over the residents' list
                HStack(spacing: 0) {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        HStack(spacing: 10) {
                            // same eye as the menu bar — notched Macs hide
                            // overflowing status items, so it lives here too
                            Button {
                                setWatching(!engine.watching)
                            } label: {
                                Image(systemName: engine.watching ? "eye" : "eye.slash")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white.opacity(engine.watching ? 0.55 : 0.4))
                                    .padding(7)
                                    .background(.black.opacity(0.42), in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help(engine.watching
                                ? L("Chamber is watching — click to close its eyes (camera off, silent)")
                                : L("Chamber is asleep — click to wake it"))
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { showSettings.toggle() }
                            } label: {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .padding(7)
                                    .background(.black.opacity(0.42), in: Circle())
                                    .overlay(Circle().stroke(.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain)
                            .help(L("Chamber settings"))
                        }
                        AgentSidebar(engine: engine)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }

                // settings live INSIDE the chamber window, over the radar
                if showSettings {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showSettings = false } }
                    SettingsView(engine: engine) {
                        withAnimation(.easeOut(duration: 0.15)) { showSettings = false }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                // asleep: one obvious way back in, at the eye's centre
                if !engine.watching, !showSettings {
                    Button {
                        setWatching(true)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "eye")
                            Text(L("Wake"))
                        }
                        .font(.callout.weight(.semibold))
                        .fontDesign(.rounded)
                        .foregroundStyle(Color(white: 0.25))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color(white: 0.92), in: Capsule())
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            // onboarding steps (calibrate also serves recalibration over the live radar)
            switch step {
            case .camera:
                CameraStepView(tracker: tracker) { step = .calibrate }
            case .calibrate:
                CalibrationStepView(tracker: tracker, engine: engine, standalone: live) {
                    step = live ? .none : .fit
                }
            case .fit:
                FitStepView(engine: engine) {
                    engine.setImmersionArmed(immersionEnabled)
                    live = true
                    step = .none
                }
            case .none:
                EmptyView()
            }

            if showDebug {
                TrackingDebugView(tracker: tracker, engine: engine) { showDebug = false }
            }

            // intro gate
            if !live && step == .none && !showDebug {
                introCard
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        // the room exists (muted) from launch so live-bridge state — binds, narration,
        // done-summaries — accumulates correctly before the user clicks in
        .onAppear {
            engine.setup()
            menuBar.install()
            // menu-bar eye mirrors the in-window one; both flip watching
            menuBar.onToggle = { setWatching(!engine.watching) }
            // dev harness: CHAMBER_DEV=talkback locks onto a fake agent at launch so
            // the panel's focus-steal mechanics are testable with no daemon or camera
            if ProcessInfo.processInfo.environment["CHAMBER_DEV"]?.hasPrefix("talkback") == true {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { engine.talkbackHarness() }
            }
            // dev harness: CHAMBER_DEV=snooze exercises snooze/unsnooze on the first
            // listed agent and dumps the list state (UI-independent engine check)
            if ProcessInfo.processInfo.environment["CHAMBER_DEV"] == "snooze" {
                func dump(_ tag: String) {
                    NSLog("[snoozedev] %@: %@", tag,
                          engine.agentList.map { "\($0.id)=\($0.snoozed ? "z" : "-")" }.joined(separator: " "))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    // a local fake bind so the harness works in live mode too
                    engine.bridgeBind(seat: 0, agent: "dev-snooze", name: "wren",
                                      kind: "demo", title: "snooze harness", input: "demo")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    dump("before")
                    if let seat = engine.agentList.first?.id { engine.setSnoozed(seat, true) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    dump("after-snooze")
                    if let seat = engine.agentList.first?.id { engine.setSnoozed(seat, false) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { dump("after-unsnooze") }
            }
        }
        // Settings buttons act here — calibration needs this window's overlay.
        .onReceive(NotificationCenter.default.publisher(for: .init("chamber.recalibrate"))) { _ in
            if enabled {
                withAnimation(.easeOut(duration: 0.15)) { showSettings = false }
                step = .calibrate
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("chamber.showDebug"))) { _ in
            if enabled { showDebug = true }
        }
    }

    private var introCard: some View {
        VStack(spacing: 18) {
            Text("Chamber").font(.system(size: 28, weight: .bold))
            Text(L("A team of agents, working around you in space. You hear them murmur as they work, and chime when they finish — turn to face one to listen."))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                req("🎧", L("Headphones required"), L("The audio is positioned in 3D — it only works over headphones."))
                req("📷", L("Camera access"), L("Turn your head to face agents. Video never leaves your device."))
            }
            if !enabled {
                Button(L("Enable camera & continue")) { enable() }.buttonStyle(.borderedProminent)
            } else {
                // Only reached with a restored calibration — a fresh user went
                // straight into onboarding when the camera came up.
                Button(L("Start")) {
                    engine.setImmersionArmed(immersionEnabled)
                    live = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tracker.faceFound)
                Text(tracker.faceFound ? L("Calibration restored") : L("Looking for your face…"))
                    .font(.caption).foregroundStyle(tracker.faceFound ? .green : .secondary)
                Button(L("Set up again")) { step = .camera }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                Button(L("Debug tracking →")) { showDebug = true }
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
        engine.openRoom() // setup() already ran at launch; this un-mutes
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
        // fresh users go straight into onboarding; returning ones get the fast path
        if !tracker.hasSavedCalibration { step = .camera }
    }

    private func startDebug() { showDebug = true }

    /// The one watching toggle both eyes (menu bar + in-window) call: engine
    /// silence, camera on/off, and both icons stay in sync.
    private func setWatching(_ on: Bool) {
        engine.setWatching(on)
        if on { tracker.resume() } else { tracker.pause() }
        menuBar.sync(on)
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
