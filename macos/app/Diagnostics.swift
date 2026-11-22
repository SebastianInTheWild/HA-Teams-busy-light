import Foundation

/// Text for "Copy Diagnostics" in the settings window: everything needed to
/// understand a problem, without the webhook ID
enum Diagnostics {
    static func text(monitor: TeamsMonitor, settings: AppSettings, updateChecker: UpdateChecker) -> String {
        let process = ProcessInfo.processInfo
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        func time(_ date: Date?) -> String { date.map { iso.string(from: $0) } ?? "–" }
        func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

        let manual: String
        if monitor.manualActive, let value = monitor.manual {
            manual = "\(value.status)" + (value.until == .distantFuture ? " (until reset)" : " until \(time(value.until))")
        } else {
            manual = "no"
        }
        let pause: String
        if monitor.sendingPaused, let until = monitor.pausedUntil {
            pause = until == .distantFuture ? "until resumed" : "until \(time(until))"
        } else {
            pause = "no"
        }
        let networks = settings.homeNetworks.isEmpty ? "(everywhere)" : settings.homeNetworks

        var lines = [
            "Teams Busy Light \(updateChecker.currentVersion) (macOS app)",
            "macOS:            \(process.operatingSystemVersionString), \(architecture)",
            "Signature:        \(Updater.isSupported ? "certificate (in-app updates)" : "ad hoc (no in-app updates)")",
            "Update channel:   \(settings.preReleases ? "with pre-releases" : "releases")",
            "Update available: \(updateChecker.availableVersion ?? "no")",
            "",
            "Teams running:    \(yesNo(Teams.isRunning))",
            "Log access:       \(monitor.logAccessDenied ? "MISSING (Full Disk Access)" : "ok")",
            "Teams presence:   \(monitor.teamsPresence ?? "–") -> \(monitor.status ?? "–")",
            "Teams call:       \(yesNo(monitor.teamsInCall))",
            "Manual status:    \(manual)",
            "Camera in use:    \(yesNo(monitor.camera))",
            "Microphone:       \(monitor.microphone ? "in use by \(monitor.microphoneUsers.joined(separator: ", "))" : "not in use")",
            "Other calls:      \(settings.detectOtherCalls ? "on" : "off")",
            "Effective:        status \(monitor.effectiveStatus ?? "–"), activity \(monitor.inCall ? "in_call" : "not_in_call")",
            "",
            "Webhook:          \(redactedWebhook(settings.webhookURL))",
            "Home networks:    \(networks)",
            "Current networks: \(HomeNetwork.currentNetworks().joined(separator: ", "))",
            "In home network:  \(yesNo(!monitor.awayFromHome))",
            "Paused:           \(pause)",
            "Last sent:        \(time(monitor.lastSent))",
            "Last error:       \(monitor.sendError ?? "–")",
            "Intervals:        check \(settings.pollSeconds) s, keep-alive \(settings.heartbeatSeconds) s",
            "Start at login:   \(yesNo(LoginItem.isEnabled))",
            "",
            "Last log lines:",
        ]
        lines += lastLogLines(40).map(redact)
        return lines.joined(separator: "\n") + "\n"
    }

    private static var architecture: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// Scheme, host and port only
    static func redactedWebhook(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return url.isEmpty ? "(not set)" : "(invalid)"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(components.scheme ?? "?")://\(host)\(port)/api/webhook/<hidden>"
    }

    /// Removes webhook IDs from a line
    static func redact(_ line: String) -> String {
        line.replacingOccurrences(of: "/api/webhook/[^\\s\"']+", with: "/api/webhook/<hidden>", options: .regularExpression)
    }

    private static func lastLogLines(_ count: Int) -> [String] {
        guard let text = try? String(contentsOf: Log.url, encoding: .utf8) else { return ["(no log)"] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(count).map(String.init))
    }
}
