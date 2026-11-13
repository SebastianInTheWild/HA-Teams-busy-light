import AppKit
import IOKit.pwr_mgt

/// Reads the own presence from the Teams logfiles.
///
/// The Mac client logs the presence with language-neutral English values
/// (e.g. "Busy"), regardless of the language of the Teams app:
///   AppMenuMac: UpdateIconPresenceSending presence update to icon v2: Busy
///   tmpcore::TmpcoreService: OnAvailabilityUpdate Received availability update: Busy cloud type: ...
/// Only the part of the newest logfile that was added since the last check
/// is read.
final class TeamsLogReader {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs")

    private static let pattern = try! NSRegularExpression(
        pattern: "(?:presence update to icon v2|Received availability update): ([^\\n]*)"
    )

    private var currentFile: URL?
    private var offset: UInt64 = 0
    private(set) var presence: String?
    /// True when the folder cannot be read (no access to data of other apps)
    private(set) var accessDenied = false

    /// Last known presence without spaces, e.g. "DoNotDisturb"
    func latestPresence() -> String? {
        let fileManager = FileManager.default
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: Self.directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
            .filter { $0.lastPathComponent.hasPrefix("MSTeams_") && $0.pathExtension == "log" }
            .sorted { modificationDate($0) > modificationDate($1) }
            accessDenied = false
        } catch {
            accessDenied = true
            return presence
        }
        guard let newest = files.first else { return presence }

        if newest != currentFile {
            // New logfile (start or rotation): read it completely and search
            // older files if it has no presence yet
            currentFile = newest
            let (found, end) = scan(newest, from: 0)
            offset = end
            if let found {
                presence = found
            } else {
                for older in files.dropFirst() {
                    if let found = scan(older, from: 0).presence {
                        presence = found
                        break
                    }
                }
            }
        } else {
            let size = fileSize(newest)
            if size < offset {
                offset = 0
            }
            if size > offset {
                let (found, end) = scan(newest, from: offset)
                offset = end
                if let found {
                    presence = found
                }
            }
        }
        return presence
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64) ?? 0
    }

    /// Last presence in the complete lines after `start`, and the offset
    /// after the last complete line
    private func scan(_ url: URL, from start: UInt64) -> (presence: String?, end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, start) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
        } catch {
            return (nil, start)
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return (nil, start) }

        let complete = data[data.startIndex...lastNewline]
        let end = start + UInt64(complete.count)
        let text = String(decoding: complete, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = Self.pattern.matches(in: text, range: range).last,
              let valueRange = Range(match.range(at: 1), in: text)
        else { return (nil, end) }

        var value = String(text[valueRange])
        if let cloud = value.range(of: " cloud type:") {
            value = String(value[..<cloud.lowerBound])
        }
        value = value.filter { !$0.isWhitespace }
        return (value.isEmpty ? nil : value, end)
    }
}

enum Teams {
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.microsoft.teams2" || $0.executableURL?.lastPathComponent == "MSTeams"
        }
    }

    /// Teams holds the power assertion "Microsoft Teams Call in progress"
    /// during a call (same as shown by "pmset -g assertions")
    static var isInCall: Bool {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as NSDictionary?
        else { return false }
        for case let assertions as [NSDictionary] in byProcess.allValues {
            for assertion in assertions {
                if let name = assertion["AssertName"] as? String, name.contains("Microsoft Teams Call in progress") {
                    return true
                }
            }
        }
        return false
    }

    /// Maps a Teams presence value to the state of the integration. Teams does
    /// not use consistent casing, so the value is compared in lower case
    /// without spaces.
    static func mapPresence(_ presence: String) -> String? {
        switch presence.lowercased().filter({ !$0.isWhitespace }) {
        case "available", "availableidle": return "available"
        case "busy", "busyidle": return "busy"
        case "inacall", "onthephone": return "in_a_call"
        case "inameeting", "inaconferencecall": return "in_a_meeting"
        case "presenting": return "presenting"
        case "focusing": return "focusing"
        case "donotdisturb": return "do_not_disturb"
        case "berightback": return "be_right_back"
        case "away", "awayidle": return "away"
        case "offline", "invisible", "appearoffline": return "offline"
        default: return nil
        }
    }
}

/// Sends status and activity to the webhook of the integration
enum Webhook {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    static let computerName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    /// Calls `completion` on the main queue with nil on success or the reason
    static func send(url: String, status: String?, inCall: Bool, completion: @escaping (String?) -> Void) {
        guard let target = URL(string: url) else {
            completion(L.invalidWebhook)
            return
        }
        var body: [String: String] = ["computer": computerName, "activity": inCall ? "in_call" : "not_in_call"]
        if let status {
            body["status"] = status
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { _, response, error in
            var reason: String?
            if let error {
                reason = error.localizedDescription
            } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                reason = "HTTP \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))"
            }
            DispatchQueue.main.async { completion(reason) }
        }.resume()
    }

    /// Sends and waits (used when quitting or going to sleep)
    static func sendAndWait(url: String, status: String, inCall: Bool, timeout: TimeInterval) {
        guard let target = URL(string: url) else { return }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "computer": computerName, "status": status, "activity": inCall ? "in_call" : "not_in_call",
        ])
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// Watches Teams and sends every change and a keep-alive to Home Assistant
final class TeamsMonitor {
    private(set) var status: String?
    private(set) var inCall = false
    private(set) var lastSent: Date?
    private(set) var sendError: String?
    /// True while "send only in these networks" is set and the Mac is in none of them
    private(set) var awayFromHome = false
    /// Sending paused from the menu until this time (`distantFuture` = until resumed)
    private(set) var pausedUntil = SendPause.load()
    var sendingPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var logAccessDenied: Bool { logReader.accessDenied }

    /// Called on the main queue whenever something shown in the menu changes
    var onChange: (() -> Void)?
    /// Called on every check while not in a home network (to offer adding it)
    var onAway: (() -> Void)?

    private var settings: AppSettings
    private let logReader = TeamsLogReader()
    private var timer: Timer?
    private var sending = false
    private var sentStatus: String?
    private var sentInCall: Bool?
    private var retryAfter = Date.distantPast
    private var unknownLogged: String?
    private var accessLogged = false
    private var paused = false

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(settings.pollSeconds), repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    /// Applies new settings and sends right away
    func update(settings: AppSettings) {
        self.settings = settings
        sentStatus = nil
        sendError = nil
        retryAfter = .distantPast
        start()
    }

    /// True when the webhook is set and the Mac is in an allowed network
    var maySend: Bool {
        settings.isConfigured && !sendingPaused && HomeNetwork.isHome(settings.homeNetworks)
    }

    /// Stops sending until the given time; Home Assistant gets `offline` once
    func pauseSending(until: Date) {
        let tellHomeAssistant = maySend
        pausedUntil = until
        SendPause.save(until)
        Log.write(until == .distantFuture ? "Sending paused" : "Sending paused until \(until)")
        if tellHomeAssistant {
            Webhook.send(url: settings.webhookURL, status: "offline", inCall: false) { _ in }
        }
        sendError = nil
        onChange?()
    }

    func resumeSending() {
        pausedUntil = nil
        SendPause.save(nil)
        Log.write("Sending resumed")
        sentStatus = nil
        retryAfter = .distantPast
        onChange?()
        sendIfNeeded()
    }

    /// Stops checking and tells Home Assistant (e.g. before sleep)
    func pause() {
        paused = true
        timer?.invalidate()
        if maySend {
            Webhook.sendAndWait(url: settings.webhookURL, status: "offline", inCall: false, timeout: 3)
        }
        sentStatus = nil
    }

    func resume() {
        paused = false
        retryAfter = .distantPast
        start()
    }

    private func check() {
        guard !paused else { return }
        var changed = false

        if Teams.isRunning {
            if let presence = logReader.latestPresence() {
                if let mapped = Teams.mapPresence(presence) {
                    if mapped != status {
                        status = mapped
                        changed = true
                    }
                } else if presence != unknownLogged {
                    // Keep the previous status, but report the value so it can be added
                    Log.write("Unknown Teams presence: \(presence)")
                    unknownLogged = presence
                }
            }
            if logReader.accessDenied && !accessLogged {
                Log.write("Cannot read the Teams logs in \(TeamsLogReader.directory.path)")
                accessLogged = true
                changed = true
            }
            let call = Teams.isInCall
            if call != inCall {
                inCall = call
                changed = true
            }
        } else if status != "offline" || inCall {
            status = "offline"
            inCall = false
            changed = true
        }

        if pausedUntil != nil && !sendingPaused {
            resumeSending()
        }

        let away = !HomeNetwork.isHome(settings.homeNetworks)
        if away != awayFromHome {
            awayFromHome = away
            if away {
                // Nothing is sent; Home Assistant sets Teams offline after its timeout
                Log.write("Not in a home network, sending paused")
                sendError = nil
            } else {
                Log.write("Back in a home network, sending again")
                sentStatus = nil
                retryAfter = .distantPast
            }
            onChange?()
        }
        if away {
            onAway?()
        }

        if changed {
            Log.write("Status: \(status ?? "none"), activity: \(inCall ? "in_call" : "not_in_call")")
            onChange?()
        }
        sendIfNeeded()
    }

    private func sendIfNeeded() {
        guard settings.isConfigured, !awayFromHome, !sendingPaused, !sending, Date() >= retryAfter else { return }
        let due = Date().timeIntervalSince(lastSent ?? .distantPast) >= TimeInterval(settings.heartbeatSeconds)
        guard status != sentStatus || inCall != sentInCall || due else { return }

        let sendStatus = status
        let sendInCall = inCall
        sending = true
        Webhook.send(url: settings.webhookURL, status: sendStatus, inCall: sendInCall) { [weak self] reason in
            guard let self else { return }
            self.sending = false
            if self.awayFromHome || self.sendingPaused {
                return
            }
            if let reason {
                if reason != self.sendError {
                    Log.write("Failed to send status to Home Assistant: \(reason)")
                }
                self.sendError = reason
                self.retryAfter = Date().addingTimeInterval(10)
            } else {
                if self.sendError != nil {
                    Log.write("Home Assistant reachable again")
                }
                self.sendError = nil
                self.sentStatus = sendStatus
                self.sentInCall = sendInCall
                self.lastSent = Date()
            }
            self.onChange?()
        }
    }

    /// Detection once, for "--show"
    static func describe() -> String {
        let reader = TeamsLogReader()
        let presence = reader.latestPresence()
        return """
        Teams running: \(Teams.isRunning ? "yes" : "no")
        Presence:      \(presence ?? (reader.accessDenied ? "no access to the logs" : "unknown")) -> \(presence.flatMap(Teams.mapPresence) ?? "not mapped")
        In a call:     \(Teams.isInCall ? "yes" : "no")
        """
    }
}
