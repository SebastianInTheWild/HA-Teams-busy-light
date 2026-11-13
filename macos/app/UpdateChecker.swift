import Foundation

/// Checks the latest GitHub release once a day. A signed app can install the
/// update itself (see Updater), otherwise the release page is opened.
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest")!
    /// TEAMS_BUSY_LIGHT_UPDATE_API replaces the GitHub API for tests (e.g. a
    /// local server); only the signature check protects the update anyway
    private static let testAPI = ProcessInfo.processInfo.environment["TEAMS_BUSY_LIGHT_UPDATE_API"].flatMap(URL.init(string:))
    private static let api = testAPI
        ?? URL(string: "https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases/latest")!

    /// Newer version than the installed one, e.g. "1.3.0"
    private(set) var availableVersion: String?
    /// Download of the macOS app of that version, if it can be installed from the app
    private(set) var downloadURL: URL?
    var onChange: (() -> Void)?

    private var timer: Timer?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    func setEnabled(_ enabled: Bool) {
        timer?.invalidate()
        timer = nil
        guard enabled, currentVersion != "0.0.0" else {
            availableVersion = nil
            downloadURL = nil
            onChange?()
            return
        }
        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    func check() {
        var request = URLRequest(url: Self.api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String
            else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let download = assets.first { $0["name"] as? String == Updater.assetName }?["browser_download_url"] as? String
            var downloadURL = download.flatMap(URL.init(string:))
            if (downloadURL?.scheme != "https" && Self.testAPI == nil) || !Updater.isSupported {
                downloadURL = nil
            }
            DispatchQueue.main.async {
                let newer = Self.isNewer(latest, than: self.currentVersion) ? latest : nil
                let url = newer == nil ? nil : downloadURL
                if newer != self.availableVersion || url != self.downloadURL {
                    if let newer {
                        Log.write("Update available: \(newer)\(url != nil ? " (can be installed from the app)" : "")")
                    }
                    self.availableVersion = newer
                    self.downloadURL = url
                    self.onChange?()
                }
            }
        }.resume()
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (value: String) in value.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
