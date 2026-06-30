import SwiftUI

@main
struct ChamberAppMain: App {
    var body: some Scene {
        WindowGroup("Chamber") { ContentView() }
            .defaultSize(width: 480, height: 660)
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
                    Text("Turn to face an agent to hear it open up · look down to whisper all")
                        .font(.caption2).foregroundStyle(.tertiary)
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
        .frame(minWidth: 460, minHeight: 600)
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
                    if tracker.hasSavedCalibration { live = true } else { runCalibration() }
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
        engine.setUse6DoF(true)
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

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("← Back") { back() }.buttonStyle(.borderless)
                Spacer()
                Text("PnP tracking debug").font(.headline)
                Spacer()
                Text(String(format: "%.0f Hz", tracker.hz)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                CameraPreview(session: tracker.session)
                    .frame(width: 320, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.45))
                    Canvas { ctx, size in
                        for (i, p) in tracker.landmarks01.enumerated() {
                            let x = p.x * size.width
                            let y = (1 - p.y) * size.height // normalized y-up -> view y-down
                            let rect = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
                            ctx.fill(Path(ellipseIn: rect), with: .color(colors[i % colors.count]))
                        }
                    }
                    Text("detected landmarks").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(6)
                }
                .frame(width: 240, height: 240)
            }
            HStack(spacing: 12) {
                ForEach(0..<labels.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(colors[i]).frame(width: 8, height: 8)
                        Text(labels[i]).font(.caption2)
                    }
                }
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

            Text("Record this while you: look left → look right → lean in → lean left/right.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 620)
        .background(Color(red: 0.04, green: 0.047, blue: 0.063))
    }
}
