import Foundation

// The lightweight update check: GitHub's releases API, at most once a day,
// and never a dialog — a quiet row in Settings ▸ About plus a small dot on
// the gear. Deliberately not Sparkle: no framework, no keys, no appcast;
// "update" means clicking through to the notarized zip like the first time.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Update {
        let version: String
        let url: URL
    }

    @Published var available: Update?
    @Published var checking = false
    @Published var checkedOnce = false // gate "Up to date" behind a real check

    /// The automatic daily check is opt-out; "Check now" stays available either
    /// way — clicking it IS the consent.
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Self.autoKey) }
    }

    static let current: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private static let lastKey = "update.lastCheck"
    private static let autoKey = "update.autoCheck"
    private static let api =
        URL(string: "https://api.github.com/repos/cfoust/antiphon/releases/latest")!

    /// Launch-time check, throttled to once a day so we're a polite API citizen.
    func checkIfDue() {
        guard autoCheck else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        check()
    }

    /// Manual check (Help menu / Settings). Fail-open: network trouble just
    /// means no news.
    func check() {
        guard !checking else { return }
        checking = true
        Task {
            defer {
                checking = false
                checkedOnce = true
            }
            var req = URLRequest(url: Self.api)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastKey)
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.newer(latest, than: Self.current) else {
                available = nil
                return
            }
            // prefer the versioned zip; fall back to the release page
            var url = (json["html_url"] as? String).flatMap(URL.init(string:))
            if let assets = json["assets"] as? [[String: Any]],
               let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-macOS.zip") == true }),
               let s = zip["browser_download_url"] as? String,
               let u = URL(string: s) {
                url = u
            }
            if let url { available = Update(version: latest, url: url) }
        }
    }

    /// Dot-numeric compare, CalVer-friendly: 2026.7.10 > 2026.7.4 > 2026.7.
    static func newer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
