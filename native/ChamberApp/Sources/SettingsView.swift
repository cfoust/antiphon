import SwiftUI

// The settings window (gear, top-right of the main window). Two panes:
// General (the sound/tracking controls that used to crowd the radar) and
// Voices (TTS providers + the discovered voice pool, served by chamberd's
// /config + /voices endpoints). Warm paper, SF Rounded — the letter's skin.

let ROOM_NAMES = ["dry", "room (FDN)", "hall (FDN)", "cathedral (FDN)", "room (BRIR)", "hall (BRIR)"]

// MARK: - daemon settings client (localhost HTTP)

struct ProviderStatus: Decodable, Equatable {
    let enabled: Bool
    let needsKey: Bool
    let keySet: Bool
    let active: Bool
    enum CodingKeys: String, CodingKey {
        case enabled, needsKey = "needs_key", keySet = "key_set", active
    }
}

struct VoicePoolEntry: Decodable {
    let provider: String
    let id: String
    let name: String
}

enum SettingsClient {
    private static func base() -> URL? {
        guard let port = ChamberDaemon.discover() else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    static func getConfig() async -> [String: ProviderStatus]? {
        guard let url = base()?.appendingPathComponent("config") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct R: Decodable { let providers: [String: ProviderStatus] }
        return (try? JSONDecoder().decode(R.self, from: data))?.providers
    }

    /// Partial update: only the fields present are changed.
    static func putConfig(_ providers: [String: [String: Any]]) async -> [String: ProviderStatus]? {
        guard let url = base()?.appendingPathComponent("config"),
              let body = try? JSONSerialization.data(withJSONObject: ["providers": providers])
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        struct R: Decodable { let providers: [String: ProviderStatus] }
        return (try? JSONDecoder().decode(R.self, from: data))?.providers
    }

    static func getVoices(refresh: Bool) async -> (voices: [VoicePoolEntry], errors: [String: String])? {
        guard var url = base()?.appendingPathComponent("voices") else { return nil }
        if refresh { url.append(queryItems: [URLQueryItem(name: "refresh", value: "1")]) }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct R: Decodable {
            let voices: [VoicePoolEntry]?
            let errors: [String: String]?
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else { return nil }
        return (r.voices ?? [], r.errors ?? [:])
    }
}

// MARK: - the window

struct SettingsView: View {
    @ObservedObject var engine: ChamberEngine
    @State private var pane = "general"

    var body: some View {
        HStack(spacing: 0) {
            // left rail
            VStack(alignment: .leading, spacing: 4) {
                Text("SETTINGS")
                    .font(.caption2.weight(.semibold)).kerning(1.2)
                    .foregroundStyle(TB.faint)
                    .padding(.bottom, 6)
                navItem("general", icon: "slider.horizontal.3", label: "General")
                navItem("voices", icon: "waveform", label: "Voices")
                Spacer()
                Text("Chamber")
                    .font(.caption2).foregroundStyle(TB.faint)
            }
            .padding(16)
            .frame(width: 168, alignment: .leading)
            .background(TB.paper)

            Rectangle().fill(TB.hairline).frame(width: 1)

            // content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if pane == "general" {
                        GeneralPane(engine: engine)
                    } else {
                        VoicesPane()
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(TB.field)
        }
        .fontDesign(.rounded)
        .preferredColorScheme(.light)
        .frame(minWidth: 700, minHeight: 520)
    }

    private func navItem(_ id: String, icon: String, label: String) -> some View {
        Button {
            pane = id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(label).font(.callout)
                Spacer()
            }
            .foregroundStyle(pane == id ? TB.ink : TB.sub)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(pane == id ? TB.ink.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var engine: ChamberEngine

    var body: some View {
        Text("General").font(.title2.weight(.semibold)).foregroundStyle(TB.ink)

        card("Sound") {
            labeledRow("Room", "The acoustic the agents live in") {
                Picker("", selection: Binding(get: { engine.roomIndex }, set: { engine.setRoom($0) })) {
                    ForEach(ROOM_NAMES.indices, id: \.self) { Text(ROOM_NAMES[$0]).tag($0) }
                }
                .labelsHidden().frame(width: 170)
            }
            if engine.roomIndex >= 4 {
                divider()
                labeledRow("Reverb tail", "Blend the parametric tail with the measured one") {
                    HStack(spacing: 8) {
                        Text("FDN").font(.caption2).foregroundStyle(TB.sub)
                        Slider(value: Binding(get: { engine.reverbBlend },
                                              set: { engine.setReverbBlend($0) }), in: 0...1)
                            .frame(width: 150)
                        Text("BRIR").font(.caption2).foregroundStyle(TB.sub)
                    }
                }
            }
            divider()
            labeledRow("HRTF fit", "Dial until a voice straight ahead sits out in front at ear level") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { engine.freqScale },
                                          set: { engine.setFreqScale($0) }), in: 0.7...2.2)
                        .frame(width: 170)
                    Text(String(format: "%.2f", engine.freqScale))
                        .font(.caption.monospacedDigit()).foregroundStyle(TB.sub)
                }
            }
        }

        card("Presence") {
            labeledRow("Immersion fade", "Close your eyes and the scene fills in; open them and it recedes") {
                Toggle("", isOn: Binding(get: { engine.immersionArmedPub },
                                         set: { engine.setImmersionArmed($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }

        card("Tracking") {
            labeledRow("Calibration", "Re-run the look-left / look-right sweep in the main window") {
                Button("Recalibrate") {
                    NotificationCenter.default.post(name: .init("chamber.recalibrate"), object: nil)
                }
            }
            divider()
            labeledRow("Diagnostics", "Landmarks, latency and the eye-closure signal, live") {
                Button("Open tracking debug") {
                    NotificationCenter.default.post(name: .init("chamber.showDebug"), object: nil)
                }
            }
        }
    }
}

// MARK: - Voices

private struct VoicesPane: View {
    @State private var providers: [String: ProviderStatus] = [:]
    @State private var counts: [String: Int] = [:]
    @State private var errors: [String: String] = [:]
    @State private var total = 0
    @State private var keyDrafts: [String: String] = [:]
    @State private var loading = true
    @State private var applying = false
    @State private var daemonUp = true

    private let order: [(id: String, label: String, blurb: String)] = [
        ("elevenlabs", "ElevenLabs", "Your voice library, discovered from the account"),
        ("openai", "OpenAI", "The speech API's built-in voices"),
        ("macos-say", "macOS", "The system voices — free, offline, always the fallback"),
    ]

    var body: some View {
        Text("Voices").font(.title2.weight(.semibold)).foregroundStyle(TB.ink)
        Text("Each agent draws a voice at random from the pool below when it first joins, and keeps it for the life of the session.")
            .font(.callout).foregroundStyle(TB.sub)
            .fixedSize(horizontal: false, vertical: true)

        if !daemonUp {
            card("") {
                Text("chamberd isn't running — start the app's live mode and come back.")
                    .font(.callout).foregroundStyle(TB.clay)
            }
        } else if loading {
            ProgressView().controlSize(.small)
        } else {
            // pool summary
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2").foregroundStyle(TB.coral)
                Text("\(total) voices in the pool")
                    .font(.callout.weight(.medium)).foregroundStyle(TB.ink)
                Spacer()
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.caption)
                }
            }
            .padding(14)
            .background(TB.paper, in: RoundedRectangle(cornerRadius: 12))

            ForEach(order, id: \.id) { p in
                providerCard(p.id, label: p.label, blurb: p.blurb)
            }

            HStack {
                Spacer()
                Button {
                    Task { await apply() }
                } label: {
                    Text(applying ? "Applying…" : "Apply")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(TB.coral)
                .disabled(applying)
            }
        }
        Spacer(minLength: 0)
            .task { await load(refresh: false) }
    }

    @ViewBuilder
    private func providerCard(_ id: String, label: String, blurb: String) -> some View {
        let st = providers[id]
        card(label) {
            labeledRow(blurb, statusLine(id, st)) {
                Toggle("", isOn: Binding(
                    get: { st?.enabled ?? true },
                    set: { on in
                        var cur = providers[id] ?? ProviderStatus(enabled: on, needsKey: id != "macos-say", keySet: false, active: false)
                        cur = ProviderStatus(enabled: on, needsKey: cur.needsKey, keySet: cur.keySet, active: cur.active)
                        providers[id] = cur
                    }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if st?.needsKey == true {
                divider()
                labeledRow("API key", st?.keySet == true ? "A key is saved — enter a new one to replace it" : "No key yet") {
                    SecureField(st?.keySet == true ? "••••••••" : "paste key", text: Binding(
                        get: { keyDrafts[id] ?? "" },
                        set: { keyDrafts[id] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
            }
        }
    }

    private func statusLine(_ id: String, _ st: ProviderStatus?) -> String {
        guard let st else { return "" }
        if let err = errors[id] { return "discovery failed: \(err)" }
        if !st.enabled { return "off" }
        if st.needsKey && !st.keySet { return "needs an API key" }
        if let n = counts[id] { return "\(n) voices" }
        return st.active ? "active" : "inactive"
    }

    private func load(refresh: Bool) async {
        loading = counts.isEmpty
        guard let cfg = await SettingsClient.getConfig() else {
            daemonUp = false; loading = false; return
        }
        daemonUp = true
        providers = cfg
        if let v = await SettingsClient.getVoices(refresh: refresh) {
            var c: [String: Int] = [:]
            for entry in v.voices { c[entry.provider, default: 0] += 1 }
            counts = c
            errors = v.errors
            total = v.voices.count
        }
        loading = false
    }

    private func apply() async {
        applying = true
        var body: [String: [String: Any]] = [:]
        for (id, st) in providers {
            var p: [String: Any] = ["enabled": st.enabled]
            if let draft = keyDrafts[id], !draft.isEmpty { p["api_key"] = draft }
            body[id] = p
        }
        if let updated = await SettingsClient.putConfig(body) {
            providers = updated
            keyDrafts = [:]
            _ = await load(refresh: true)
        }
        applying = false
    }
}

// MARK: - shared bits

@ViewBuilder
private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        if !title.isEmpty {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(TB.ink)
        }
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TB.paper, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(TB.hairline))
}

private func labeledRow(_ title: String, _ sub: String,
                        @ViewBuilder trailing: () -> some View) -> some View {
    HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(TB.ink)
            if !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(TB.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Spacer(minLength: 12)
        trailing()
    }
}

private func divider() -> some View {
    Rectangle().fill(TB.hairline).frame(height: 1)
}
