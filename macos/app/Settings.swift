import Foundation

/// Settings of Teams Busy Light, stored in the user defaults of the app
/// (com.teamsbusylight.app). install.sh migrates the settings.sh of the
/// script version into these keys.
struct AppSettings: Equatable {
    var webhookURL = ""
    var heartbeatSeconds = 60
    var pollSeconds = 2
    var checkForUpdates = true
    /// Send only while the Mac is in one of these networks (CIDR, comma
    /// separated); empty = everywhere
    var homeNetworks = ""
    /// Ask whether to add a network that is not in homeNetworks
    var askForNewNetworks = true
    /// Networks the user chose not to add (not asked again)
    var ignoredNetworks = ""

    private enum Key {
        static let webhookURL = "webhookURL"
        static let heartbeatSeconds = "heartbeatSeconds"
        static let pollSeconds = "pollSeconds"
        static let checkForUpdates = "checkForUpdates"
        static let homeNetworks = "homeNetworks"
        static let askForNewNetworks = "askForNewNetworks"
        static let ignoredNetworks = "ignoredNetworks"
    }

    static func load() -> AppSettings {
        let defaults = UserDefaults.standard
        var settings = AppSettings()
        settings.webhookURL = (defaults.string(forKey: Key.webhookURL) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if defaults.object(forKey: Key.heartbeatSeconds) != nil {
            settings.heartbeatSeconds = min(max(defaults.integer(forKey: Key.heartbeatSeconds), 10), 3600)
        }
        if defaults.object(forKey: Key.pollSeconds) != nil {
            settings.pollSeconds = min(max(defaults.integer(forKey: Key.pollSeconds), 1), 60)
        }
        if defaults.object(forKey: Key.checkForUpdates) != nil {
            settings.checkForUpdates = defaults.bool(forKey: Key.checkForUpdates)
        }
        settings.homeNetworks = (defaults.string(forKey: Key.homeNetworks) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if defaults.object(forKey: Key.askForNewNetworks) != nil {
            settings.askForNewNetworks = defaults.bool(forKey: Key.askForNewNetworks)
        }
        settings.ignoredNetworks = defaults.string(forKey: Key.ignoredNetworks) ?? ""
        return settings
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(webhookURL, forKey: Key.webhookURL)
        defaults.set(heartbeatSeconds, forKey: Key.heartbeatSeconds)
        defaults.set(pollSeconds, forKey: Key.pollSeconds)
        defaults.set(checkForUpdates, forKey: Key.checkForUpdates)
        defaults.set(homeNetworks, forKey: Key.homeNetworks)
        defaults.set(askForNewNetworks, forKey: Key.askForNewNetworks)
        defaults.set(ignoredNetworks, forKey: Key.ignoredNetworks)
    }

    var isConfigured: Bool { AppSettings.isValidWebhook(webhookURL) }

    static func isValidWebhook(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return false }
        return value.range(of: "/api/webhook/[^/]+$", options: .regularExpression) != nil
    }
}

/// Sending paused from the menu, kept over restarts. `distantFuture` means
/// until resumed.
enum SendPause {
    private static let key = "pausedUntil"

    static func load() -> Date? {
        UserDefaults.standard.object(forKey: key) as? Date
    }

    static func save(_ until: Date?) {
        if let until {
            UserDefaults.standard.set(until, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// Starts the app at login with a LaunchAgent. The app is started through
/// LaunchServices ("open"), so macOS treats it like an app started from the
/// Finder (permissions belong to the app, not to launchd).
enum LoginItem {
    static let label = "com.teamsbusylight.agent"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Writes or removes the LaunchAgent; it takes effect at the next login
    static func setEnabled(_ enabled: Bool) throws {
        let fileManager = FileManager.default
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-g", "-a", Bundle.main.bundleURL.path],
                "RunAtLoad": true,
                "LimitLoadToSessionType": "Aqua",
                "ProcessType": "Interactive",
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else if fileManager.fileExists(atPath: plistURL.path) {
            try fileManager.removeItem(at: plistURL)
        }
    }

    /// Enables the login item after the first start, and rewrites an enabled
    /// one so it points to the current location of the app
    static func refresh() {
        let key = "loginItemConfigured"
        guard isEnabled || !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try setEnabled(true)
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            Log.write("Cannot enable start at login: \(error.localizedDescription)")
        }
    }
}

/// Simple log in ~/Library/Logs/TeamsBusyLight.log (one older log is kept)
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TeamsBusyLight.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let fileManager = FileManager.default
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > 1_000_000 {
            let old = url.appendingPathExtension("old")
            try? fileManager.removeItem(at: old)
            try? fileManager.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}
