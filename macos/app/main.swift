import AppKit
import SwiftUI
import UserNotifications

/// Menu bar app: shows the Teams status, sends it to Home Assistant and
/// offers the settings. Command line:
///   TeamsBusyLight --show                         print the detected state once
///   TeamsBusyLight --set-status busy [in_call]    send a status once
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var settings = AppSettings.load()
    private var monitor: TeamsMonitor!
    private let updateChecker = UpdateChecker()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var signalSource: DispatchSourceSignal?
    private var accessHintShown = false
    /// Kept in the user defaults: macOS may restart the app when the access
    /// is granted, and the new instance still confirms it
    private var accessWasDenied: Bool {
        get { UserDefaults.standard.bool(forKey: "logAccessDenied") }
        set { UserDefaults.standard.set(newValue, forKey: "logAccessDenied") }
    }
    private var settingsModel: SettingsModel?

    private let statusLine = NSMenuItem()
    private let activityLine = NSMenuItem()
    private let connectionLine = NSMenuItem()
    private let accessItem = NSMenuItem(title: L.menuNoLogAccess, action: #selector(showAccessHint), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "", action: #selector(openReleasePage), keyEquivalent: "")
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("Teams Busy Light \(updateChecker.currentVersion) started on \(Webhook.computerName)")
        NSApp.mainMenu = makeMainMenu()
        makeStatusItem()

        monitor = TeamsMonitor(settings: settings)
        monitor.onChange = { [weak self] in self?.refresh() }
        monitor.onAway = { [weak self] in self?.offerNewNetwork() }
        updateChecker.onChange = { [weak self] in self?.updateChanged() }
        UNUserNotificationCenter.current().delegate = self
        LoginItem.refresh()

        // Tell Home Assistant before the Mac goes to sleep
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("Going to sleep")
            self?.monitor.pause()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("Woke up")
            self?.monitor.resume()
        }

        // "kill" (e.g. by install.sh) quits like the menu, so offline is sent
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        signalSource = source

        monitor.start()
        updateChecker.setEnabled(settings.checkForUpdates)
        refresh()
        if !settings.isConfigured {
            showSettings()
        }
    }

    /// Double-click on the app while it is running
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if monitor.maySend {
            Webhook.sendAndWait(url: settings.webhookURL, status: "offline", inCall: false, timeout: 3)
        }
        Log.write("Teams Busy Light stopped")
        return .terminateNow
    }

    // MARK: Menus

    /// The main menu is not visible in a menu bar app, but its key equivalents
    /// make cut, copy and paste work in the settings window
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        return mainMenu
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Stable name, so macOS and menu bar managers remember the position
        statusItem.autosaveName = "TeamsBusyLightStatus"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in [statusLine, activityLine, connectionLine] {
            item.isEnabled = false
            menu.addItem(item)
        }
        accessItem.target = self
        menu.addItem(accessItem)
        menu.addItem(.separator())
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(withTitle: L.menuSettings, action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L.menuShowLog, action: #selector(showLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    /// Updates the icon and the menu
    private func refresh() {
        let statusName = L.statusName(monitor.status)
        statusLine.title = L.menuStatus(statusName)
        activityLine.title = L.menuActivity(L.activityName(inCall: monitor.inCall))
        connectionLine.toolTip = nil
        if !settings.isConfigured {
            connectionLine.title = L.menuNotConfigured
        } else if monitor.awayFromHome {
            connectionLine.title = L.menuAway
        } else if let error = monitor.sendError {
            connectionLine.title = L.menuSendFailed
            connectionLine.toolTip = error
        } else if let lastSent = monitor.lastSent {
            connectionLine.title = L.menuSentAt(timeFormatter.string(from: lastSent))
        } else {
            connectionLine.title = L.menuConnecting
        }
        accessItem.isHidden = !monitor.logAccessDenied
        if monitor.logAccessDenied {
            if !accessWasDenied {
                accessWasDenied = true
            }
        } else if accessWasDenied && monitor.status != nil {
            accessWasDenied = false
            Log.write("Access to the Teams logs granted")
            notify(id: "access", L.accessGranted, alertIfNotAllowed: true)
        }
        settingsModel?.logAccess = Teams.isRunning ? !monitor.logAccessDenied : nil
        if monitor.logAccessDenied && !accessHintShown {
            // Once per start: without access the app cannot work, and the
            // menu bar icon may be hidden (e.g. behind the notch)
            accessHintShown = true
            DispatchQueue.main.async { [weak self] in self?.showAccessHint() }
        }
        if let version = updateChecker.availableVersion {
            updateItem.title = L.menuUpdate(version)
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }

        statusItem.button?.image = icon()
        statusItem.button?.toolTip = "Teams Busy Light – \(statusName)"
    }

    /// Same as the tray icon on Windows: the brand icon with a colored dot in
    /// the lower right corner (none while the status is unknown)
    private func icon() -> NSImage? {
        var dot: NSColor?
        if monitor.inCall {
            dot = Self.dotColors["busy"]
        } else if let status = monitor.status {
            switch status {
            case "available": dot = Self.dotColors["available"]
            case "be_right_back", "away": dot = Self.dotColors["away"]
            case "offline": dot = Self.dotColors["offline"]
            default: dot = Self.dotColors["busy"]
            }
        }
        let brand = NSImage(named: NSImage.applicationIconName)
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            brand?.draw(in: rect)
            if let dot {
                let diameter = size / 2
                let ring = NSRect(x: size - diameter, y: 0, width: diameter, height: diameter)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: ring).fill()
                dot.setFill()
                NSBezierPath(ovalIn: ring.insetBy(dx: size / 16, dy: size / 16)).fill()
            }
            return true
        }
        // Fixed name: menu bar managers (e.g. Thaw, Ice) identify the item by
        // it, so it must not change with the status (shown in the tooltip)
        image.accessibilityDescription = "Teams Busy Light"
        return image
    }

    private static let dotColors: [String: NSColor] = [
        "available": NSColor(srgbRed: 92 / 255, green: 184 / 255, blue: 92 / 255, alpha: 1),
        "busy": NSColor(srgbRed: 212 / 255, green: 52 / 255, blue: 70 / 255, alpha: 1),
        "away": NSColor(srgbRed: 250 / 255, green: 176 / 255, blue: 40 / 255, alpha: 1),
        "offline": NSColor(srgbRed: 150 / 255, green: 150 / 255, blue: 150 / 255, alpha: 1),
    ]

    // MARK: Actions

    @objc private func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(settings: settings, autostart: LoginItem.isEnabled)
            model.logAccess = Teams.isRunning ? !monitor.logAccessDenied : nil
            settingsModel = model
            let view = SettingsView(
                model: model,
                currentStatus: { [weak self] in (self?.monitor.status, self?.monitor.inCall ?? false) },
                onSave: { [weak self] settings, autostart in self?.apply(settings, autostart: autostart) },
                onClose: { [weak self] in self?.settingsWindow?.close() },
                onGrantAccess: { [weak self] in self?.openAccessSettings() }
            )
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: controller)
            window.title = L.settingsTitle
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.settingsWindow = nil
                self?.settingsModel = nil
            }
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func apply(_ newSettings: AppSettings, autostart: Bool) {
        if autostart != LoginItem.isEnabled {
            do {
                try LoginItem.setEnabled(autostart)
            } catch {
                let alert = NSAlert()
                alert.messageText = L.autostartFailed(error.localizedDescription)
                alert.runModal()
            }
        }
        let updatesChanged = newSettings.checkForUpdates != settings.checkForUpdates
        newSettings.save()
        settings = newSettings
        Log.write("Settings saved")
        monitor.update(settings: settings)
        if updatesChanged {
            updateChecker.setEnabled(settings.checkForUpdates)
        }
        refresh()
        settingsWindow?.close()
    }

    private var askingNetwork = false

    /// Asks whether to add a network the Mac is in that is not a home network
    /// yet. "Don't Add" remembers the network, so it is asked only once.
    private func offerNewNetwork() {
        guard settings.askForNewNetworks, !askingNetwork, settingsWindow == nil,
              let network = HomeNetwork.newNetworks(home: settings.homeNetworks, ignored: settings.ignoredNetworks).first
        else { return }
        askingNetwork = true
        // Not inside the timer callback of the monitor
        DispatchQueue.main.async { [self] in
            defer { askingNetwork = false }
            let alert = NSAlert()
            alert.messageText = L.newNetworkTitle(network)
            alert.informativeText = L.newNetworkText
            alert.addButton(withTitle: L.addNetwork)
            alert.addButton(withTitle: L.dontAddNetwork)
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L.dontAskAgain
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()

            var newSettings = settings
            if response == .alertFirstButtonReturn {
                newSettings.homeNetworks = HomeNetwork.adding([network], to: settings.homeNetworks)
                Log.write("Network added: \(network)")
            } else {
                newSettings.ignoredNetworks = HomeNetwork.adding([network], to: settings.ignoredNetworks)
                Log.write("Network not added: \(network)")
            }
            if alert.suppressionButton?.state == .on {
                newSettings.askForNewNetworks = false
            }
            newSettings.save()
            settings = newSettings
            monitor.update(settings: settings)
            refresh()
        }
    }

    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) {
            Log.write("Log created")
        }
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func showAccessHint() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L.menuNoLogAccess
        alert.informativeText = L.noLogAccessHint
        alert.addButton(withTitle: L.openPrivacySettings)
        alert.addButton(withTitle: L.ok)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessSettings()
        }
    }

    /// Opens Full Disk Access and a Finder window with the app selected, so
    /// it can be dragged into the list
    private func openAccessSettings() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openReleasePage() {
        NSWorkspace.shared.open(UpdateChecker.releasesPage)
    }

    // MARK: Update hint

    /// Shows a notification once per new version
    private func updateChanged() {
        refresh()
        let key = "notifiedVersion"
        guard let version = updateChecker.availableVersion,
              UserDefaults.standard.string(forKey: key) != version
        else { return }
        UserDefaults.standard.set(version, forKey: key)
        notify(id: "update", L.updateNotification(version))
    }

    /// Shows a notification; when notifications are not allowed, optionally
    /// a dialog instead
    private func notify(id: String, _ body: String, alertIfNotAllowed: Bool = false) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                Log.write("Notifications are not allowed")
                if alertIfNotAllowed {
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        let alert = NSAlert()
                        alert.messageText = "Teams Busy Light"
                        alert.informativeText = body
                        alert.runModal()
                    }
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Teams Busy Light"
            content.body = body
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "update" {
            NSWorkspace.shared.open(UpdateChecker.releasesPage)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

// MARK: Start

let arguments = CommandLine.arguments

if arguments.contains("--show") {
    print(TeamsMonitor.describe())
    exit(0)
}

if let index = arguments.firstIndex(of: "--set-status") {
    let settings = AppSettings.load()
    guard settings.isConfigured else {
        FileHandle.standardError.write(Data("No webhook URL set. Open the app to enter it.\n".utf8))
        exit(1)
    }
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write(Data("Usage: TeamsBusyLight --set-status <status> [in_call|not_in_call]\n".utf8))
        exit(2)
    }
    let status = arguments[index + 1]
    let inCall = index + 2 < arguments.count && arguments[index + 2] == "in_call"
    Webhook.send(url: settings.webhookURL, status: status, inCall: inCall) { reason in
        if let reason {
            FileHandle.standardError.write(Data("Failed: \(reason)\n".utf8))
            exit(1)
        }
        print("Sent status \(status), activity \(inCall ? "in_call" : "not_in_call").")
        exit(0)
    }
    dispatchMain()
}

// Only one instance (LaunchServices prevents a second one, but not a start
// of the executable from the command line)
if let identifier = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0 != .current }) {
    print("Teams Busy Light is already running.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
