import Foundation

// BridgeClient — connects the native app to chamberd (docs/agent-bridge.md, M3).
//
// The app OWNS the daemon: adopt one that's already running (discovery file with a
// live pid), else spawn the bundled binary and supervise it. The /stream WebSocket
// then drives the live experience: bind/free = agent presence, task/progress/blocked
// = narration lines (decoded to 48 k mono and queued per agent), done = the spoken
// summary + the existing done/ping/linger flow. If neither adopting nor spawning
// works, the app quietly stays in demo mode.

/// One /stream frame (superset of all types; see docs/agent-bridge.md).
private struct Frame: Decodable {
    let type: String
    let seat: Int?
    let name: String?
    let headline: String?
    let note: String?
    let summary: String?
    let question: String?
    let audioB64: String?
    let audioUrl: String?
}

enum ChamberDaemon {
    static var stateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".chamber")
    }

    /// Port of a live daemon per the discovery file, or nil.
    static func discover() -> Int? {
        let url = stateDir.appendingPathComponent("chamberd.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = obj["port"] as? Int else { return nil }
        if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0 {
            return nil // stale file from an unclean shutdown
        }
        return port
    }

    /// Locate the chamberd binary: env override, next to the app executable
    /// (bundled by make.sh), the repo dev build, PATH-ish fallbacks.
    static func findBinary() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CHAMBERD"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("chamberd"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent("go/bin/chamberd"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/chamberd"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/chamberd"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

final class BridgeClient: NSObject {
    private weak var engine: ChamberEngine?
    private let decodeQ = DispatchQueue(label: "chamber.bridge.decode", qos: .utility)
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var daemon: Process?
    private var port = 8787
    private var retry = 0
    private var stopped = false

    init(engine: ChamberEngine) {
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
        if let p = ChamberDaemon.discover() {
            port = p
            print("[bridge] adopted running chamberd on :\(port)")
        } else if let bin = ChamberDaemon.findBinary() {
            let proc = Process()
            proc.executableURL = bin
            proc.arguments = ["serve"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                daemon = proc
                print("[bridge] spawned chamberd (\(bin.path))")
            } catch {
                print("[bridge] failed to spawn chamberd: \(error)")
                return false
            }
        } else {
            print("[bridge] no chamberd binary found — demo mode")
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

    private func connect() {
        guard !stopped else { return }
        guard let url = URL(string: "ws://127.0.0.1:\(port)/stream") else { return }
        let t = session.webSocketTask(with: url)
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
            // the daemon may have moved ports / been restarted by hand
            if let p = ChamberDaemon.discover() { self.port = p }
            self.connect()
        }
    }

    private func handle(_ f: Frame) {
        guard let engine else { return }
        switch f.type {
        case "hello":
            engine.bridgeConnected(true)
        case "bind":
            if let seat = f.seat { engine.bridgeBind(seat: seat) }
        case "free":
            if let seat = f.seat { engine.bridgeFree(seat: seat) }
        case "task", "progress", "blocked", "done":
            guard let seat = f.seat else { return }
            let isDone = f.type == "done"
            guard let b64 = f.audioB64 else {
                if isDone { engine.bridgeDone(seat: seat, summary: []) }
                return
            }
            let ext = (f.audioUrl as NSString?)?.pathExtension ?? "mp3"
            decodeQ.async { [weak engine] in
                guard let engine else { return }
                let samples = Self.decode(b64: b64, ext: ext.isEmpty ? "mp3" : ext)
                if isDone {
                    engine.bridgeDone(seat: seat, summary: samples)
                } else if !samples.isEmpty {
                    engine.bridgeNarration(seat: seat, samples: samples)
                }
            }
        default:
            break
        }
    }

    /// Decode compressed audio bytes to 48 kHz mono floats. AVAudioFile wants a
    /// real file, so round-trip through a temp path (cheap; lines are seconds long).
    private static func decode(b64: String, ext: String) -> [Float] {
        guard let data = Data(base64Encoded: b64) else { return [] }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("chamber-line-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
        } catch {
            return []
        }
        return loadMono(tmp) ?? []
    }
}
