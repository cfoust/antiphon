import Foundation

// BridgeClient — connects the native app to antiphond (protocol: plugins/README.md).
//
// The app OWNS the daemon: adopt one that's already running (discovery file with a
// live pid), else spawn the bundled binary and supervise it. The /stream WebSocket
// then drives the live experience: bind/free = agent presence, task/progress/blocked
// = narration lines (decoded to 48 k mono and queued per agent), done = the spoken
// summary + the existing done/ping/linger flow. If neither adopting nor spawning
// works, the app quietly stays in demo mode.

/// One /stream frame (superset of all frame types; protocol: plugins/README.md).
private struct Frame: Decodable {
    let type: String
    let seat: Int?
    let agent: String?
    let name: String?
    let kind: String?
    let title: String?
    let input: String?
    let repo: String?
    let cwd: String?
    let branch: String?
    let headline: String?
    let note: String?
    let summary: String?
    let question: String?
    let audioB64: String?
    let audioUrl: String?

    /// The narration text a frame carries, by type (mirrors the hub's FIELD map).
    var text: String? {
        switch type {
        case "task": return headline
        case "progress": return note
        case "done": return summary
        case "blocked": return question
        default: return nil
        }
    }
}

enum AntiphonDaemon {
    static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".antiphon")
    }

    /// Port of a live daemon per the discovery file, or nil.
    static func discover() -> Int? {
        let url = stateDir.appendingPathComponent("antiphond.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int else { return nil }
        if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0 {
            return nil // stale file from an unclean shutdown
        }
        return port
    }

    /// Fire-and-forget daemon start (Settings uses this): no supervision handle —
    /// the daemon writes its discovery file and the bridge adopts it later. If a
    /// daemon already holds the port, the new instance exits on bind: harmless.
    @discardableResult
    static func spawnDetached() -> Bool {
        guard let bin = findBinary() else { return false }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            NSLog("[bridge] settings spawned antiphond (%@)", bin.path)
            return true
        } catch {
            NSLog("[bridge] settings spawn failed: %@", "\(error)")
            return false
        }
    }

    /// Locate the antiphond binary: env override, next to the app executable
    /// (bundled by make.sh), the repo dev build, PATH-ish fallbacks.
    static func findBinary() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["ANTIPHOND"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("antiphond"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("go/bin/antiphond"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/antiphond"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/antiphond"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

final class BridgeClient: NSObject {
    private weak var engine: AntiphonEngine?
    private let decodeQ = DispatchQueue(label: "antiphon.bridge.decode", qos: .utility)
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var daemon: Process?
    private var port = 8787
    private var retry = 0
    private var stopped = false

    init(engine: AntiphonEngine) {
        self.engine = engine
        super.init()
        session = URLSession(configuration: .ephemeral)
        // if we spawned the daemon, take it down with the app (an adopted one stays)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSApplicationWillTerminateNotification"),
            object: nil, queue: nil
        ) { [weak self] _ in self?.daemon?.terminate() }
    }

    /// Adopt or spawn the daemon, then connect. Returns false when no daemon can
    /// exist (no binary anywhere) — the app should stay in demo mode.
    @discardableResult
    func start() -> Bool {
        if let p = AntiphonDaemon.discover() {
            port = p
            print("[bridge] adopted running antiphond on :\(port)")
        } else if let bin = AntiphonDaemon.findBinary() {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["serve"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                daemon = proc
                print("[bridge] spawned antiphond (\(bin.path))")
            } catch {
                print("[bridge] failed to spawn antiphond: \(error)")
                return false
            }
        } else {
            print("[bridge] no antiphond binary found — demo mode")
            return false
        }
        connect()
        return true
    }

    func stop() {
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        daemon?.terminate()
    }

    /// Talk-back: route the user's words to the agent on `seat` (hub deliverSay →
    /// pane injection / channel). Fire-and-forget; delivery failures are hub-side.
    func sendSay(seat: Int, text: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["type": "say", "seat": seat, "text": text]),
            let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { err in
            if let err { NSLog("[bridge] say send failed: %@", "\(err)") }
        }
    }

    private func connect() {
        guard !stopped else { return }
        guard let url = URL(string: "ws://127.0.0.1:\(port)/stream") else { return }
        let t = session.webSocketTask(with: url)
        // The default cap is 1 MiB — a long done-summary's inline base64 audio
        // exceeds it, which kills the receive (and the frame) with a reconnect.
        t.maximumMessageSize = 64 << 20
        task = t
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let msg):
                if self.retry != 0 { self.retry = 0 }
                if case .string(let s) = msg, let data = s.data(using: .utf8),
                   let frame = try? JSONDecoder().decode(Frame.self, from: data) {
                    self.handle(frame)
                }
                self.receive(on: t)
            case .failure:
                self.engine?.bridgeConnected(false)
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        retry += 1
        let delay = min(30.0, 1.0 * pow(1.6, Double(min(retry, 8))))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            if let p = AntiphonDaemon.discover() {
                // the daemon may have moved ports / been restarted by hand
                self.port = p
            } else if self.retry >= 2 {
                // the daemon is gone (killed, crashed, adopted one exited) — the
                // app owns it, so supervise: bring a fresh one up
                self.respawnIfNeeded()
            }
            self.connect()
        }
    }

    private func respawnIfNeeded() {
        if let d = daemon, d.isRunning { return } // alive; it may still be starting up
        guard let bin = AntiphonDaemon.findBinary() else { return }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            daemon = proc
            NSLog("[bridge] respawned antiphond (%@)", bin.path)
        } catch {
            NSLog("[bridge] antiphond respawn failed: %@", "\(error)")
        }
    }

    private func handle(_ f: Frame) {
        // EVERYTHING goes through the serial decode queue so frame effects apply in
        // strict arrival order — a `free` must never overtake the `done` in front of
        // it that is still decoding its audio (session exits send exactly that pair).
        decodeQ.async { [weak self] in
            guard let self, let engine = self.engine else { return }
            switch f.type {
            case "hello":
                NSLog("[bridge] hello — entering live mode")
                engine.bridgeConnected(true)
            case "bind":
                if let seat = f.seat {
                    NSLog("[bridge] bind seat=%d name=%@ input=%@", seat, f.name ?? "?", f.input ?? "-")
                    engine.bridgeBind(seat: seat, agent: f.agent, name: f.name, kind: f.kind,
                                      title: f.title, input: f.input,
                                      repo: f.repo, cwd: f.cwd, branch: f.branch)
                }
            case "tool":
                if let seat = f.seat { engine.bridgeTool(seat: seat) }
            case "free":
                if let seat = f.seat {
                    NSLog("[bridge] free seat=%d", seat)
                    engine.bridgeFree(seat: seat)
                }
            case "task", "progress", "blocked", "done":
                guard let seat = f.seat else { return }
                // the words themselves feed the talk-back panel's mini-transcript
                if let line = f.text, !line.isEmpty {
                    engine.bridgeLine(seat: seat, kind: f.type, text: line)
                }
                // Prefer fetching the cached line over the inline base64 — smaller
                // frames, no message-size cliffs, same bytes (localhost).
                var ext = "mp3"
                var data: Data?
                if let path = f.audioUrl, let url = URL(string: "http://127.0.0.1:\(self.port)\(path)") {
                    ext = url.pathExtension.isEmpty ? ext : url.pathExtension
                    data = Self.fetch(url)
                }
                if data == nil, let b64 = f.audioB64 {
                    data = Data(base64Encoded: b64)
                }
                var samples: [Float] = []
                if let data { samples = Self.decode(data: data, ext: ext) }
                NSLog("[bridge] %@ seat=%d decoded=%d samples", f.type, seat, samples.count)
                if f.type == "done" {
                    engine.bridgeDone(seat: seat, summary: samples)
                } else if !samples.isEmpty {
                    engine.bridgeNarration(seat: seat, samples: samples)
                }
            default:
                break
            }
        }
    }

    /// Synchronous localhost fetch of a cached voice line (runs on decodeQ).
    private static func fetch(_ url: URL) -> Data? {
        var out: Data?
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: url) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { out = data }
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 10)
        return out
    }

    /// Decode compressed audio bytes to 48 kHz mono floats. AVAudioFile wants a
    /// real file, so round-trip through a temp path (cheap; lines are seconds long).
    private static func decode(data: Data, ext: String) -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("antiphon-line-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
        } catch {
            return []
        }
        return loadMono(tmp) ?? []
    }
}
