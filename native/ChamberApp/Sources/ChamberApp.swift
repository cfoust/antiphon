import SwiftUI

@main
struct ChamberAppMain: App {
    var body: some Scene {
        WindowGroup("Chamber") { ContentView() }
            .defaultSize(width: 400, height: 600)
    }
}

struct ContentView: View {
    @StateObject private var tracker = FaceTracker()
    @StateObject private var engine = ChamberEngine()
    @State private var calStatus = ""
    private let rooms = ["dry", "room", "hall", "cathedral", "room (BRIR)", "hall (BRIR)"]

    var body: some View {
        VStack(spacing: 12) {
            Text("Chamber").font(.headline)
            if !engine.hrtfName.isEmpty {
                Text(engine.hrtfName).font(.caption2).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    CameraPreview(session: tracker.session)
                        .frame(width: 180, height: 135)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Circle().fill(tracker.faceFound ? .green : .red).frame(width: 9, height: 9).padding(6)
                }
                Radar(engine: engine).frame(width: 150, height: 150)
            }

            if tracker.devices.count > 1 {
                Picker("Camera", selection: $tracker.selectedID) {
                    ForEach(tracker.devices) { d in Text(d.name).tag(d.id) }
                }
                .onChange(of: tracker.selectedID) { id in tracker.switchTo(id) }
                .font(.caption)
            }

            HStack(spacing: 14) {
                pose("yaw", tracker.yaw); pose("pitch", tracker.pitch); pose("roll", tracker.roll)
            }
            HStack {
                Text(tracker.status).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "vision %.0f Hz · cam %.0f fps", tracker.hz, tracker.configuredFPS))
                    .monospacedDigit().foregroundStyle(.secondary)
            }.font(.caption)

            Divider()

            HStack {
                Button(calStatus.isEmpty ? "Calibrate" : calStatus) { calibrate() }
                    .disabled(!calStatus.isEmpty)
                Spacer()
                Picker("Room", selection: Binding(get: { engine.roomIndex }, set: { engine.setRoom($0) })) {
                    ForEach(rooms.indices, id: \.self) { Text(rooms[$0]).tag($0) }
                }.frame(width: 130).font(.caption)
            }.font(.caption)

            HStack {
                Toggle("auto-finish", isOn: Binding(get: { engine.autoFinish }, set: { engine.setAutoFinish($0) }))
                    .toggleStyle(.switch)
                Spacer()
                Button("finish one") { engine.finishOne() }
            }.font(.caption)

            Toggle("invert pitch (if look-down feels backwards)", isOn: $tracker.pitchInvert).font(.caption2)

            Text("Headphones on. Turn to face an agent to hear it open up; look down to whisper everyone. Agents finish on their own — face one and hold ~1.5s for its summary.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            engine.setup()
            tracker.onOrient = { [weak engine] d in engine?.setOrient(deg: d) }
            tracker.onGate = { [weak engine] g in engine?.setLookGate(g) }
            tracker.onPosition = { [weak engine] x, y, z in engine?.setPosition(x, y, z) }
            tracker.start()
        }
    }

    private func calibrate() {
        Task { @MainActor in
            calStatus = "Look left…"
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            let yl = tracker.yaw, pl = tracker.pitch
            calStatus = "Now look right…"
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            let yr = tracker.yaw, pr = tracker.pitch
            tracker.calibrate(yawLeftRad: yl, yawRightRad: yr, neutralPitchRad: (pl + pr) / 2)
            calStatus = "Calibrated ✓"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            calStatus = ""
        }
    }

    private func pose(_ label: String, _ radians: Double) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(String(format: "%+.0f°", deg(radians))).font(.body).monospacedDigit()
        }.frame(width: 70)
    }
}
