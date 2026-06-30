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
    @State private var calArrow = ""
    @State private var calText = ""
    private let rooms = ["dry", "room", "hall", "cathedral", "room (BRIR)", "hall (BRIR)"]

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

            // intro gate
            if !live && calText.isEmpty {
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
                Button("Start") { runCalibration() }.buttonStyle(.borderedProminent)
                    .disabled(!tracker.faceFound)
                Text(tracker.faceFound ? "Head tracking ready" : "Looking for your face…")
                    .font(.caption).foregroundStyle(tracker.faceFound ? .green : .secondary)
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
        engine.setUse6DoF(true)
        tracker.start()
        enabled = true
    }

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
            calArrow = "✓"; calText = "Calibrated"
            try? await Task.sleep(nanoseconds: 900_000_000)
            calText = ""; calArrow = ""
            live = true
        }
    }
}
