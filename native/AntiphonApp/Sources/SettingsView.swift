import ServiceManagement
import SwiftUI

// Settings (gear, top-right) — an overlay INSIDE the antiphon window, dark to
// match it. Two panes: General (the sound/tracking controls that used to
// crowd the radar) and Voices (TTS providers + the discovered voice pool,
// served by antiphond's /config + /voices endpoints).

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

struct VoicePoolEntry: Decodable, Identifiable, Equatable {
    let provider: String
    let id: String
    let name: String
    var enabled: Bool
}

enum SettingsClient {
    private static func base() -> URL? {
        // The discovery file is a hint, not a gate: it goes stale on unclean
        // shutdowns while a daemon may well be serving the default port. The
        // request that follows is the real liveness probe.
        let port = AntiphonDaemon.discover() ?? 8787
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

    /// Live per-voice sample: the daemon synthesizes with ITS key, we play it.
    static func audition(provider: String, voice: String, text: String) async -> (Data, String)? {
        guard var comps = base().flatMap({ URLComponents(url: $0.appendingPathComponent("audition"),
                                                         resolvingAgainstBaseURL: false) }) else { return nil }
        comps.queryItems = [.init(name: "provider", value: provider),
                            .init(name: "voice", value: voice),
                            .init(name: "text", value: text)]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let ext = http.value(forHTTPHeaderField: "x-audition-ext") ?? "wav"
        return (data, ext)
    }

    /// Which persona is using which spoken voice right now (assignment dots).
    struct AgentVoice: Decodable {
        let seat: Int?
        let connected: Bool?
        let tts_provider: String?
        let tts_voice: String?
    }
    static func getAgents() async -> [AgentVoice]? {
        guard let url = base()?.appendingPathComponent("agents"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct R: Decodable { let agents: [AgentVoice]? }
        if let r = try? JSONDecoder().decode(R.self, from: data) { return r.agents }
        return try? JSONDecoder().decode([AgentVoice].self, from: data)
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
    let engine: AntiphonEngine // deliberately NOT observed — see GeneralPane
    @ObservedObject var updates: UpdateChecker
    var onClose: () -> Void = {}
    @ObservedObject private var i18n = I18n.shared
    // dev: ANTIPHON_DEV containing "voices" opens straight onto the Voices pane
    @State private var pane = ProcessInfo.processInfo
        .environment["ANTIPHON_DEV"]?.contains("voices") == true ? "voices" : "general"

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
                Text("Antiphon")
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
                        GeneralPane(engine: engine, updates: updates)
                    } else {
                        VoicesPane(engine: engine)
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
    // NOT @ObservedObject: the engine publishes pose/immersion at 30-60 Hz and
    // observing it re-rendered this whole pane on every tick (janky scrolling).
    // The pane reads once and mirrors what it edits in local state.
    let engine: AntiphonEngine
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var i18n = I18n.shared
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var fit = 2.0
    @State private var fadeDelay = 0.6
    @State private var waitingCue = true
    @State private var sysMode = "deaden"
    @State private var sysDist = 2.2

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Text(L("General")).font(.title2.weight(.semibold)).foregroundStyle(SD.ink)
            .onAppear {
                fit = engine.freqScale
                fadeDelay = engine.fadeDelay
                waitingCue = engine.attentionCue
                let ud = UserDefaults.standard
                sysMode = ud.string(forKey: "sysaudio.mode") ?? "deaden"
                sysDist = ud.object(forKey: "sysaudio.dist") != nil ? ud.double(forKey: "sysaudio.dist") : 2.2
            }

        card(L("Sound")) {
            // hovering the row takes over the room: the guide voice loops from
            // straight ahead until it sits truly out in front of you
            labeledRow(L("Fit"), L("Adjust until my voice sits straight ahead of you")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { fit },
                                          set: { fit = $0; engine.setFreqScale($0) }), in: 0.7...2.2)
                        .frame(width: 170)
                    Text(String(format: "%.2f", fit))
                        .font(.caption.monospacedDigit()).foregroundStyle(SD.sub)
                }
            }
            .onHover { over in
                if over { engine.onboardPlay("fit", loop: true, bearingDeg: 0) }
                else { engine.onboardStop() }
            }
        }

        card(L("Immersion")) {
            labeledRow(L("Waiting cue"),
                       L("With your eyes open, agents that finished build a quiet chord over minutes")) {
                Toggle("", isOn: Binding(get: { waitingCue },
                                         set: { waitingCue = $0; engine.setAttentionCue($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            divider()
            labeledRow(L("Fade-in delay"),
                       L("How long your eyes stay closed before the room fades in — raise it if blinks trigger it")) {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { fadeDelay },
                                          set: { fadeDelay = $0; engine.setFadeDelay($0) }), in: 0...3)
                        .frame(width: 170)
                    Text(String(format: "%.1f s", fadeDelay))
                        .font(.caption.monospacedDigit()).foregroundStyle(SD.sub)
                }
            }
        }

        card(L("The rest of your Mac")) {
            if #available(macOS 14.4, *) {
                labeledRow(L("When the scene is in"),
                           L("Everything else your Mac plays steps back — or joins the room as a virtual speaker pair")) {
                    Picker("", selection: Binding(
                        get: { sysMode },
                        set: { sysMode = $0; engine.setSystemAudio(mode: $0) })) {
                        Text(L("As is")).tag("off")
                        Text(L("Quieter")).tag("deaden")
                        Text(L("In the room")).tag("spatial")
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 260)
                }
                if sysMode == "spatial" {
                    divider()
                    labeledRow(L("Distance"), L("How far away the virtual pair sits")) {
                        HStack(spacing: 8) {
                            Slider(value: Binding(get: { sysDist },
                                                  set: { sysDist = $0; engine.setSystemAudioDistance($0) }),
                                   in: 1.0...3.0)
                                .frame(width: 170)
                            Text(String(format: "%.1f m", sysDist))
                                .font(.caption.monospacedDigit()).foregroundStyle(SD.sub)
                        }
                    }
                }
            } else {
                Text(L("Requires macOS 14.4 or later."))
                    .font(.callout).foregroundStyle(SD.faint)
            }
        }

        card(L("Tracking")) {
            labeledRow(L("Calibration"), L("Re-run the look-left / look-right sweep in the main window")) {
                Button(L("Recalibrate")) {
                    NotificationCenter.default.post(name: .init("antiphon.recalibrate"), object: nil)
                }
            }
            divider()
            labeledRow(L("Diagnostics"), L("Landmarks, latency and the eye-closure signal, live")) {
                Button(L("Open tracking debug")) {
                    NotificationCenter.default.post(name: .init("antiphon.showDebug"), object: nil)
                }
            }
        }

        card(L("Startup")) {
            labeledRow(L("Start at login"), L("Antiphon opens quietly when you log in")) {
                Toggle("", isOn: Binding(
                    get: { loginItem },
                    set: { on in
                        // register/unregister can throw (e.g. running from a DMG);
                        // re-read the real status either way so the UI never lies
                        try? on ? SMAppService.mainApp.register()
                                : SMAppService.mainApp.unregister()
                        loginItem = SMAppService.mainApp.status == .enabled
                    }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }

        card(L("Language")) {
            labeledRow(L("Language"), L("Menus, statuses, and the spoken cues")) {
                Picker("", selection: Binding(get: { i18n.lang }, set: { i18n.lang = $0 })) {
                    ForEach(AppLang.allCases) { l in Text(l.label).tag(l) }
                }
                .labelsHidden().frame(width: 150)
            }
        }

        card(L("About")) {
            labeledRow(L("Version"), "Antiphon") {
                Text(appVersion).font(.callout.monospacedDigit()).foregroundStyle(SD.sub)
            }
            divider()
            labeledRow(L("Check automatically"), L("Once a day, from GitHub — nothing is sent")) {
                Toggle("", isOn: Binding(get: { updates.autoCheck },
                                         set: { updates.autoCheck = $0 }))
                    .labelsHidden().toggleStyle(.switch)
            }
            divider()
            labeledRow(L("Updates"),
                       updates.available.map { Lf("New version: %@", $0.version) }
                           ?? (updates.checkedOnce ? L("Up to date") : L("Not checked yet"))) {
                if updates.checking {
                    ProgressView().controlSize(.small)
                } else if let up = updates.available {
                    Button(L("Download")) { NSWorkspace.shared.open(up.url) }
                } else {
                    Button(L("Check now")) { updates.check() }
                }
            }
            divider()
            labeledRow(L("Support"), L("Guides, the protocol, and a place to report problems")) {
                HStack(spacing: 10) {
                    Button(L("Documentation")) {
                        if let u = URL(string: "https://antiphon.dev/docs/") { NSWorkspace.shared.open(u) }
                    }
                    Button(L("Report an issue")) {
                        if let u = URL(string: "https://github.com/cfoust/antiphon/issues") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Voices

private struct VoicesPane: View {
    let engine: AntiphonEngine // audition playback (not observed — see GeneralPane)
    @ObservedObject private var i18n = I18n.shared
    @State private var providers: [String: ProviderStatus] = [:]
    @State private var voices: [String: [VoicePoolEntry]] = [:] // provider → all discovered voices
    @State private var errors: [String: String] = [:]
    @State private var keyDrafts: [String: String] = [:]
    @State private var loading = true
    @State private var applying = false
    @State private var daemonUp = true
    @State private var selected = "openai" // the rail's active provider
    @State private var assignments: [String: [String]] = [:] // "prov\0voice" → persona hexes
    @State private var auditioning: String? // voice id mid-fetch (spinner)

    private var enabledTotal: Int { voices.values.flatMap { $0 }.filter(\.enabled).count }

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
                Text(L("The audio daemon couldn't be started — see ~/.antiphon/antiphond.log."))
                    .font(.callout).foregroundStyle(SD.clay)
            }
        } else if loading {
            ProgressView().controlSize(.small)
        } else {
            // design C: providers on a rail, the selected one's voices beside it
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(order, id: \.id) { p in railItem(p.id, label: p.label) }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 158, alignment: .leading)
                .background(SD.card)

                Rectangle().fill(SD.hairline).frame(width: 1)

                VStack(alignment: .leading, spacing: 0) {
                    providerContent(selected)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 300, alignment: .top)
            .background(SD.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Text(Lf("In the pool: %@", LVoiceCount(enabledTotal)))
                    .font(.caption).foregroundStyle(SD.sub)
                Spacer()
                Button {
                    Task { await load(refresh: true) }
                } label: {
                    Label(L("Refresh"), systemImage: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(SD.sub)
            }
            .padding(.horizontal, 4)
        }
        Spacer(minLength: 0)
            .task { await load(refresh: false) }
    }

    // MARK: rail

    private func railItem(_ id: String, label: String) -> some View {
        let st = providers[id]
        let count = (voices[id] ?? []).filter(\.enabled).count
        return Button {
            selected = id
        } label: {
            HStack(spacing: 7) {
                Circle().fill(railDot(st)).frame(width: 6, height: 6)
                Text(label).font(.callout)
                Spacer(minLength: 4)
                if st?.active == true {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(SD.faint)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(selected == id ? Color.white.opacity(0.09) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(selected == id ? SD.ink : SD.sub)
        }
        .buttonStyle(.plain)
    }

    private func railDot(_ st: ProviderStatus?) -> Color {
        guard let st, st.enabled else { return .white.opacity(0.25) }
        if st.needsKey && !st.keySet { return Color(red: 0.85, green: 0.56, blue: 0.38) }
        return st.active ? Color(red: 0.49, green: 0.62, blue: 0.47) : .white.opacity(0.25)
    }

    // MARK: the selected provider

    @ViewBuilder
    private func providerContent(_ id: String) -> some View {
        let st = providers[id]
        let list = voices[id] ?? []
        let meta = order.first { $0.id == id }

        HStack(alignment: .firstTextBaseline) {
            Text(statusLine(id, st)).font(.caption).foregroundStyle(SD.sub)
            Spacer()
            Toggle("", isOn: Binding(
                get: { st?.enabled ?? true },
                set: { on in setProviderEnabled(id, on) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .help(L("Use these voices"))
        }
        .padding(.bottom, 2)
        Text(meta.map { L($0.blurb) } ?? "")
            .font(.caption).foregroundStyle(SD.faint)
            .padding(.bottom, 8)

        if st?.needsKey == true && st?.keySet != true {
            // the cloud stays locked until a key arrives — voices below preview
            // grayed, toggles and play disabled
            HStack(spacing: 8) {
                SecureField(L("paste key"), text: Binding(
                    get: { keyDrafts[id] ?? "" },
                    set: { keyDrafts[id] = $0 }))
                    .textFieldStyle(.roundedBorder)
                Button(applying ? L("Applying…") : L("Save")) {
                    Task { await saveKey(id) }
                }
                .disabled((keyDrafts[id] ?? "").isEmpty || applying)
            }
            .padding(.bottom, 10)
        } else if st?.needsKey == true {
            HStack(spacing: 8) {
                Text(L("A key is saved — enter a new one to replace it"))
                    .font(.caption2).foregroundStyle(SD.faint)
                SecureField("••••••••", text: Binding(
                    get: { keyDrafts[id] ?? "" },
                    set: { keyDrafts[id] = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 150)
                if !(keyDrafts[id] ?? "").isEmpty {
                    Button(L("Save")) { Task { await saveKey(id) } }.disabled(applying)
                }
            }
            .padding(.bottom, 10)
        }

        let unlocked = st?.active == true
        if list.isEmpty {
            Text(errors[id].map { Lf("discovery failed: %@", $0) } ?? L("No voices discovered yet"))
                .font(.caption).foregroundStyle(SD.faint)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list) { v in voiceRow(id, v, unlocked: unlocked) }
                }
            }
        }
    }

    @ViewBuilder
    private func voiceRow(_ provider: String, _ v: VoicePoolEntry, unlocked: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await audition(provider, v) }
            } label: {
                if auditioning == v.id {
                    ProgressView().controlSize(.mini).frame(width: 18, height: 18)
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(unlocked ? SD.sub : SD.faint.opacity(0.5))
                }
            }
            .buttonStyle(.plain)
            .disabled(!unlocked || auditioning != nil)
            .help(L("Hear this voice"))

            Text(v.name)
                .font(.callout)
                .foregroundStyle(unlocked && v.enabled ? SD.ink : SD.faint)

            HStack(spacing: 3) {
                ForEach(assignments["\(provider)\u{0}\(v.id)"] ?? [], id: \.self) { hex in
                    Circle().fill(Color(hex: hex)).frame(width: 7, height: 7)
                        .help(L("An agent is using this voice right now"))
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { v.enabled },
                set: { on in setVoice(provider, v.id, on) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                .disabled(!unlocked)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(SD.hairline.opacity(0.6)).frame(height: 1) }
    }

    private func audition(_ provider: String, _ v: VoicePoolEntry) async {
        auditioning = v.id
        defer { auditioning = nil }
        if let (data, ext) = await SettingsClient.audition(
            provider: provider, voice: v.id,
            text: L("A voice for your room — steady, close, and easy to live with.")) {
            engine.auditionPlay(data: data, ext: ext)
        }
    }

    private func setProviderEnabled(_ id: String, _ on: Bool) {
        if let cur = providers[id] {
            providers[id] = ProviderStatus(enabled: on, needsKey: cur.needsKey,
                                           keySet: cur.keySet, active: on && cur.active)
        }
        Task {
            _ = await SettingsClient.putConfig([id: ["enabled": on]])
            await load(refresh: false)
        }
    }

    private func saveKey(_ id: String) async {
        guard let draft = keyDrafts[id], !draft.isEmpty else { return }
        applying = true
        _ = await SettingsClient.putConfig([id: ["api_key": draft]])
        keyDrafts[id] = ""
        await load(refresh: true) // the new key unlocks discovery
        applying = false
    }

    /// Flip one voice: optimistic local update, then persist (merged server-side).
    private func setVoice(_ provider: String, _ voiceID: String, _ on: Bool) {
        if var list = voices[provider], let i = list.firstIndex(where: { $0.id == voiceID }) {
            list[i].enabled = on
            voices[provider] = list
        }
        Task { _ = await SettingsClient.putConfig([provider: ["voices": [voiceID: on]]]) }
    }

    private func statusLine(_ id: String, _ st: ProviderStatus?) -> String {
        guard let st else { return "" }
        if let err = errors[id] { return Lf("discovery failed: %@", err) }
        if !st.enabled { return L("off") }
        if st.needsKey && !st.keySet { return L("needs an API key") }
        if let list = voices[id], !list.isEmpty { return LVoiceCount(list.filter(\.enabled).count) }
        return st.active ? L("active") : L("inactive")
    }

    private func load(refresh: Bool) async {
        loading = voices.isEmpty
        var maybeCfg = await SettingsClient.getConfig()
        if maybeCfg == nil {
            // The app bundles the daemon — start it rather than sending the
            // user off to do it. A second instance self-limits (port bind).
            if AntiphonDaemon.spawnDetached() {
                for _ in 0..<6 where maybeCfg == nil {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    maybeCfg = await SettingsClient.getConfig()
                }
            }
        }
        guard let cfg = maybeCfg else {
            daemonUp = false; loading = false; return
        }
        daemonUp = true
        providers = cfg
        // which persona wears which voice, for the little assignment dots
        if let rows = await SettingsClient.getAgents() {
            var m: [String: [String]] = [:]
            for r in rows {
                guard let seat = r.seat, seat >= 0, r.connected == true,
                      let pr = r.tts_provider, let vo = r.tts_voice, !vo.isEmpty else { continue }
                m["\(pr)\u{0}\(vo)", default: []].append(AGENTS[seat % AGENTS.count].hex)
            }
            assignments = m
        }
        if let v = await SettingsClient.getVoices(refresh: refresh) {
            var grouped: [String: [VoicePoolEntry]] = [:]
            for entry in v.voices { grouped[entry.provider, default: []].append(entry) }
            voices = grouped
            errors = v.errors
        }
        loading = false
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
