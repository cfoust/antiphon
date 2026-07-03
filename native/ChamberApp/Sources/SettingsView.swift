import SwiftUI

// Settings (gear, top-right) — an overlay INSIDE the chamber window, dark to
// match it. Two panes: General (the sound/tracking controls that used to
// crowd the radar) and Voices (TTS providers + the discovered voice pool,
// served by chamberd's /config + /voices endpoints).

/// The settings' dark palette (same cool-dark family as the radar window).
enum SD {
    static let paper = Color(red: 0.058, green: 0.064, blue: 0.082)  // nav rail
    static let field = Color(red: 0.075, green: 0.081, blue: 0.101)  // content
    static let card = Color.white.opacity(0.05)
    static let ink = Color.white.opacity(0.92)
    static let sub = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.34)
    static let hairline = Color.white.opacity(0.08)
    static let coral = TB.coral
    static let clay = Color(red: 0.85, green: 0.56, blue: 0.48) // errors, lifted for dark
}

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
    var onClose: () -> Void = {}
    @ObservedObject private var i18n = I18n.shared
    @State private var pane = "general"

    var body: some View {
        HStack(spacing: 0) {
            // left rail
            VStack(alignment: .leading, spacing: 4) {
                Text(L("SETTINGS"))
                    .font(.caption2.weight(.semibold)).kerning(1.2)
                    .foregroundStyle(SD.faint)
                    .padding(.bottom, 6)
                navItem("general", icon: "slider.horizontal.3", label: L("General"))
                navItem("voices", icon: "waveform", label: L("Voices"))
                Spacer()
                Text("Chamber")
                    .font(.caption2).foregroundStyle(SD.faint)
            }
            .padding(16)
            .frame(width: 168, alignment: .leading)
            .background(SD.paper)

            Rectangle().fill(SD.hairline).frame(width: 1)

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
            .background(SD.field)
        }
        .fontDesign(.rounded)
        .frame(width: 760, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(0.09)))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SD.sub)
                    .padding(7)
                    .background(.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction) // esc lets go, like everything here
            .padding(12)
        }
        .shadow(color: .black.opacity(0.5), radius: 26, y: 8)
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
            .foregroundStyle(pane == id ? SD.ink : SD.sub)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(pane == id ? SD.ink.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var engine: ChamberEngine
    @ObservedObject private var i18n = I18n.shared

    var body: some View {
        Text(L("General")).font(.title2.weight(.semibold)).foregroundStyle(SD.ink)

        card(L("Sound")) {
            // hovering the row takes over the room: the guide voice loops from
            // straight ahead until it sits truly out in front of you
            labeledRow(L("Fit"), L("Adjust until my voice sits straight ahead of you")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { engine.freqScale },
                                          set: { engine.setFreqScale($0) }), in: 0.7...2.2)
                        .frame(width: 170)
                    Text(String(format: "%.2f", engine.freqScale))
                        .font(.caption.monospacedDigit()).foregroundStyle(SD.sub)
                }
            }
            .onHover { over in
                if over { engine.onboardPlay("fit", loop: true, bearingDeg: 0) }
                else { engine.onboardStop() }
            }
        }

        card(L("Tracking")) {
            labeledRow(L("Calibration"), L("Re-run the look-left / look-right sweep in the main window")) {
                Button(L("Recalibrate")) {
                    NotificationCenter.default.post(name: .init("chamber.recalibrate"), object: nil)
                }
            }
            divider()
            labeledRow(L("Diagnostics"), L("Landmarks, latency and the eye-closure signal, live")) {
                Button(L("Open tracking debug")) {
                    NotificationCenter.default.post(name: .init("chamber.showDebug"), object: nil)
                }
            }
        }

        card(L("Language")) {
            labeledRow(L("Language"), L("For spot-checking the translations")) {
                Picker("", selection: Binding(get: { i18n.lang }, set: { i18n.lang = $0 })) {
                    ForEach(AppLang.allCases) { l in Text(l.label).tag(l) }
                }
                .labelsHidden().frame(width: 150)
            }
        }
    }
}

// MARK: - Voices

private struct VoicesPane: View {
    @ObservedObject private var i18n = I18n.shared
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
        Text(L("Voices")).font(.title2.weight(.semibold)).foregroundStyle(SD.ink)
        Text(L("Each agent draws a voice at random from the pool below when it first joins, and keeps it for the life of the session."))
            .font(.callout).foregroundStyle(SD.sub)
            .fixedSize(horizontal: false, vertical: true)

        if !daemonUp {
            card("") {
                Text(L("chamberd isn't running — start the app's live mode and come back."))
                    .font(.callout).foregroundStyle(SD.clay)
            }
        } else if loading {
            ProgressView().controlSize(.small)
        } else {
            // pool summary
            HStack(spacing: 8) {
                Image(systemName: "person.wave.2").foregroundStyle(SD.coral)
                Text(LVoicePool(total))
                    .font(.callout.weight(.medium)).foregroundStyle(SD.ink)
                Spacer()
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Label(L("Refresh"), systemImage: "arrow.clockwise").font(.caption)
                }
            }
            .padding(14)
            .background(SD.card, in: RoundedRectangle(cornerRadius: 12))

            ForEach(order, id: \.id) { p in
                providerCard(p.id, label: p.label, blurb: L(p.blurb))
            }

            HStack {
                Spacer()
                Button {
                    Task { await apply() }
                } label: {
                    Text(applying ? L("Applying…") : L("Apply"))
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(SD.coral)
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
                labeledRow(L("API key"), st?.keySet == true ? L("A key is saved — enter a new one to replace it") : L("No key yet")) {
                    SecureField(st?.keySet == true ? "••••••••" : L("paste key"), text: Binding(
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
        if let err = errors[id] { return Lf("discovery failed: %@", err) }
        if !st.enabled { return L("off") }
        if st.needsKey && !st.keySet { return L("needs an API key") }
        if let n = counts[id] { return LVoiceCount(n) }
        return st.active ? L("active") : L("inactive")
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
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(SD.ink)
        }
        content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SD.card, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(SD.hairline))
}

private func labeledRow(_ title: String, _ sub: String,
                        @ViewBuilder trailing: () -> some View) -> some View {
    HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(SD.ink)
            if !sub.isEmpty {
                Text(sub).font(.caption).foregroundStyle(SD.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Spacer(minLength: 12)
        trailing()
    }
}

private func divider() -> some View {
    Rectangle().fill(SD.hairline).frame(height: 1)
}
