import Foundation

/// Checks the latest GitHub release once a day. A signed app can install the
/// update itself (see Updater), otherwise the release page is opened. With
/// pre-releases, the newest of the latest releases (including pre-releases)
/// is offered.
final class UpdateChecker {
    static let releasesPage = URL(string: "https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest")!
    /// TEAMS_BUSY_LIGHT_UPDATE_API replaces the GitHub API for tests (e.g. a
    /// local server); only the signature check protects the update anyway
    private static let testAPI = ProcessInfo.processInfo.environment["TEAMS_BUSY_LIGHT_UPDATE_API"].flatMap(URL.init(string:))
    private static let latestAPI = URL(string: "https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases/latest")!
    private static let listAPI = URL(string: "https://api.github.com/repos/SebastianInTheWild/HA-Teams-busy-light/releases?per_page=30")!

    /// Newer version than the installed one, e.g. "1.3.0"
    private(set) var availableVersion: String?
    /// Download of the macOS app of that version, if it can be installed from the app
    private(set) var downloadURL: URL?
    /// Release page of that version
    private(set) var releasePage = UpdateChecker.releasesPage
    var onChange: (() -> Void)?

    /// Channel of the daily check: true = also pre-releases
    private var preReleases = false
    private var timer: Timer?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// Starts (and checks right away) or stops the daily check; called again
    /// when the settings change
    func setEnabled(_ enabled: Bool, preReleases: Bool) {
        self.preReleases = preReleases
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

    /// After the settings window closed without saving: a check made there
    /// with the other channel is replaced by one with the saved channel
    func resyncChannel() {
        guard let checked = checkedPreReleases, checked != preReleases else { return }
        if timer != nil {
            check()
        } else {
            checkedPreReleases = nil
            availableVersion = nil
            downloadURL = nil
            onChange?()
        }
    }

    /// Channel of the last answer applied
    private var checkedPreReleases: Bool?

    /// Answer to "Check for Updates" in the menu and the settings
    enum CheckResult {
        case upToDate(String)
        case available(String)
        case failed(String)
    }

    /// Asks GitHub for the latest release. The daily check passes no
    /// completion; "Check for Updates" gets the answer on the main thread.
    /// The settings window passes the channel as chosen there.
    func check(preReleases: Bool? = nil, completion: ((CheckResult) -> Void)? = nil) {
        let withPreReleases = preReleases ?? self.preReleases
        let api = Self.testAPI ?? (withPreReleases ? Self.listAPI : Self.latestAPI)
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let release = Self.newestRelease(in: json),
                  let tag = release["tag_name"] as? String
            else {
                let status = (response as? HTTPURLResponse)?.statusCode
                let reason = error?.localizedDescription ?? status.map { "HTTP \($0)" } ?? "no answer"
                Log.write("Update check failed: \(reason)")
                DispatchQueue.main.async { completion?(.failed(reason)) }
                return
            }
            let latest = Self.trimmed(tag)
            let assets = release["assets"] as? [[String: Any]] ?? []
            let download = assets.first { $0["name"] as? String == Updater.assetName }?["browser_download_url"] as? String
            var downloadURL = download.flatMap(URL.init(string:))
            if (downloadURL?.scheme != "https" && Self.testAPI == nil) || !Updater.isSupported {
                downloadURL = nil
            }
            let page = (release["html_url"] as? String).flatMap(URL.init(string:))
                .flatMap { $0.absoluteString.hasPrefix("https://github.com/") ? $0 : nil }
            DispatchQueue.main.async {
                self.checkedPreReleases = withPreReleases
                let newer = Self.isNewer(latest, than: self.currentVersion) ? latest : nil
                let url = newer == nil ? nil : downloadURL
                // Evaluated on every check: a download added to the release
                // later, or a switch of the channel, is picked up
                if newer != self.availableVersion || url != self.downloadURL {
                    if let newer {
                        Log.write("Update available: \(newer)\(url != nil ? " (can be installed from the app)" : "")")
                    }
                    self.availableVersion = newer
                    self.downloadURL = url
                    self.releasePage = page ?? Self.releasesPage
                    self.onChange?()
                }
                completion?(newer.map(CheckResult.available) ?? .upToDate(self.currentVersion))
            }
        }.resume()
    }

    /// The newest published release of an answer of the GitHub API: one
    /// release (releases/latest) or a list (releases, with pre-releases)
    static func newestRelease(in json: Any) -> [String: Any]? {
        let releases = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
        return releases
            .filter { ($0["draft"] as? Bool) != true && !trimmed($0["tag_name"] as? String ?? "").isEmpty }
            .max { compare(trimmed($0["tag_name"] as? String ?? ""), trimmed($1["tag_name"] as? String ?? "")) < 0 }
    }

    private static func trimmed(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }

    /// Compares two versions like SemVer: 1 if a is newer, -1 if older, 0 if
    /// equal. "1.10.0" > "1.9.2", and a pre-release comes before its version:
    /// "1.6.0-beta.2" < "1.6.0-beta.10" < "1.6.0".
    static func compare(_ first: String, _ second: String) -> Int {
        let split = { (value: String) -> (core: [Int], pre: [Substring]) in
            let parts = trimmed(value).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = parts[0].split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
            let pre = parts.count > 1 ? parts[1].split(separator: ".", omittingEmptySubsequences: false) : []
            return (core, pre)
        }
        let a = split(first), b = split(second)
        for index in 0..<max(a.core.count, b.core.count) {
            let x = index < a.core.count ? a.core[index] : 0
            let y = index < b.core.count ? b.core[index] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        if a.pre == b.pre { return 0 }
        if a.pre.isEmpty { return 1 }
        if b.pre.isEmpty { return -1 }
        for index in 0..<max(a.pre.count, b.pre.count) {
            if index >= a.pre.count { return -1 }
            if index >= b.pre.count { return 1 }
            let x = a.pre[index], y = b.pre[index]
            switch (Int(x), Int(y)) {
            case let (x?, y?):
                if x != y { return x > y ? 1 : -1 }
            case (.some, nil):
                // Numbers come before words
                return -1
            case (nil, .some):
                return 1
            case (nil, nil):
                if x != y { return x > y ? 1 : -1 }
            }
        }
        return 0
    }
}
