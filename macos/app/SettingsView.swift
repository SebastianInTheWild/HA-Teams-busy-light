import AppKit
import SwiftUI

/// Values edited in the settings window. An ObservableObject instead of
/// @State, because @State is a macro in newer SDKs and the Command Line Tools
/// do not ship the SwiftUI macro plugin.
final class SettingsModel: ObservableObject {
    @Published var webhookURL: String
    @Published var heartbeatSeconds: Int
    @Published var pollSeconds: Int
    @Published var autostart: Bool
    @Published var checkForUpdates: Bool
    @Published var preReleases: Bool
    @Published var homeNetworks: String
    @Published var askForNewNetworks: Bool
    @Published var detectOtherCalls: Bool
    @Published var diagnosticsCopied = false
    @Published var tab = SettingsTab.general
    let ignoredNetworks: String
    @Published var testing = false
    @Published var testResult: (text: String, ok: Bool)?
    @Published var checkingUpdates = false
    @Published var updateCheckResult: (text: String, ok: Bool)?
    @Published var error: String?
    /// nil while Teams is not running (the access is only checked then)
    @Published var logAccess: Bool?

    init(settings: AppSettings, autostart: Bool) {
        webhookURL = settings.webhookURL
        heartbeatSeconds = settings.heartbeatSeconds
        pollSeconds = settings.pollSeconds
        self.autostart = autostart
        checkForUpdates = settings.checkForUpdates
        preReleases = settings.preReleases
        homeNetworks = settings.homeNetworks
        askForNewNetworks = settings.askForNewNetworks
        detectOtherCalls = settings.detectOtherCalls
        ignoredNetworks = settings.ignoredNetworks
    }
}

enum SettingsTab: Hashable {
    case general, detection, networks
}

/// Settings window: webhook URL with test, intervals, start at login and
/// update hint
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Current status and call state, sent by "Send Test"
    let currentStatus: () -> (status: String?, inCall: Bool)
    /// Text for "Copy Diagnostics"
    let diagnostics: () -> String
    /// "Check for Updates" with the channel as chosen in the window (true =
    /// with pre-releases): answers on the main thread
    let checkForUpdates: (Bool, @escaping (UpdateChecker.CheckResult) -> Void) -> Void
    let onSave: (AppSettings, Bool) -> Void
    let onClose: () -> Void
    let onGrantAccess: () -> Void
    let version: String

    private var trimmedURL: String {
        model.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                page {
                    Section {
                        LabeledContent(L.logAccess) {
                            switch model.logAccess {
                            case true?:
                                Label(L.logAccessOk, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case false?:
                                HStack {
                                    Label(L.logAccessMissing, systemImage: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                    Button(L.grantAccess, action: onGrantAccess)
                                }
                            case nil:
                                Text(L.logAccessUnknown).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section {
                        TextField(L.webhook, text: $model.webhookURL, prompt: Text("https://…/api/webhook/…"))
                            .onChange(of: model.webhookURL) { _ in
                                model.testResult = nil
                                model.error = nil
                            }
                        HStack {
                            Button(L.test, action: test)
                                .disabled(model.testing || trimmedURL.isEmpty)
                            if model.testing {
                                ProgressView().controlSize(.small)
                            }
                            if let testResult = model.testResult {
                                Text(testResult.text)
                                    .foregroundStyle(testResult.ok ? Color.secondary : Color.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } footer: {
                        hint(L.webhookHint)
                    }

                    Section {
                        Toggle(L.autostart, isOn: $model.autostart)
                        Toggle(L.checkForUpdates, isOn: $model.checkForUpdates)
                        Toggle(isOn: $model.preReleases) {
                            Text(L.preReleases)
                            Text(L.preReleasesHint)
                        }
                        .onChange(of: model.preReleases) { _ in model.updateCheckResult = nil }
                        HStack {
                            Button(L.checkForUpdatesNow, action: checkUpdates)
                                .disabled(model.checkingUpdates)
                            if model.checkingUpdates {
                                ProgressView().controlSize(.small)
                            }
                            if let result = model.updateCheckResult {
                                Text(result.text)
                                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .tabItem { Text(L.tabGeneral) }
                .tag(SettingsTab.general)

                page {
                    Section {
                        Toggle(L.detectOtherCalls, isOn: $model.detectOtherCalls)
                    } footer: {
                        hint(L.detectOtherCallsHint)
                    }

                    Section {
                        Stepper(L.heartbeat(model.heartbeatSeconds), value: $model.heartbeatSeconds, in: 10...3600, step: 10)
                        Stepper(L.poll(model.pollSeconds), value: $model.pollSeconds, in: 1...60)
                    } footer: {
                        hint(L.heartbeatHint)
                    }

                    Section {
                        HStack {
                            Button(L.copyDiagnostics, action: copyDiagnostics)
                            if model.diagnosticsCopied {
                                Text(L.diagnosticsCopied).foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        hint(L.diagnosticsHint)
                    }
                }
                .tabItem { Text(L.tabDetection) }
                .tag(SettingsTab.detection)

                page {
                    Section {
                        TextField(L.homeNetworks, text: $model.homeNetworks, prompt: Text("192.168.1.0/24"))
                            .onChange(of: model.homeNetworks) { _ in model.error = nil }
                        HStack {
                            Spacer()
                            Button(L.addCurrentNetwork, action: addCurrentNetwork)
                        }
                        Toggle(L.askForNewNetworks, isOn: $model.askForNewNetworks)
                    } footer: {
                        hint(L.homeNetworksHint)
                    }
                }
                .tabItem { Text(L.tabNetworks) }
                .tag(SettingsTab.networks)
            }
            .padding([.horizontal, .top], 12)

            HStack {
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L.version(version)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L.cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button(L.save, action: save)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    /// One tab: a grouped form as high as its content
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Sends the current status to the entered URL
    private func test() {
        let url = trimmedURL
        guard AppSettings.isValidWebhook(url) else {
            model.testResult = (L.invalidWebhook, false)
            return
        }
        let current = currentStatus()
        let status = current.status ?? "offline"
        model.testing = true
        model.testResult = nil
        Webhook.send(url: url, status: status, inCall: current.inCall) { reason in
            model.testing = false
            if let reason {
                model.testResult = (L.testFailed(reason), false)
            } else {
                model.testResult = (L.testOk(L.statusName(status)), true)
            }
        }
    }

    /// A newer version is only shown here and installed from the menu: the
    /// app restarts for it, and open settings would be lost
    private func checkUpdates() {
        model.checkingUpdates = true
        model.updateCheckResult = nil
        checkForUpdates(model.preReleases) { result in
            model.checkingUpdates = false
            switch result {
            case .upToDate(let version):
                model.updateCheckResult = (L.updateCheckLatest(version), true)
            case .available(let version):
                model.updateCheckResult = (L.updateCheckAvailable(version), true)
            case .failed(let reason):
                model.updateCheckResult = (L.updateCheckFailed(reason), false)
            }
        }
    }

    private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics(), forType: .string)
        model.diagnosticsCopied = true
    }

    /// Appends the networks the Mac is in right now
    private func addCurrentNetwork() {
        let current = HomeNetwork.currentNetworks()
        guard !current.isEmpty else {
            model.error = L.noCurrentNetwork
            return
        }
        model.homeNetworks = HomeNetwork.adding(current, to: model.homeNetworks)
    }

    private func save() {
        let url = trimmedURL
        guard AppSettings.isValidWebhook(url) else {
            model.error = L.invalidWebhook
            model.tab = .general
            return
        }
        let networks = model.homeNetworks.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalid = HomeNetwork.parse(networks).invalid {
            model.error = L.invalidNetwork(invalid)
            model.tab = .networks
            return
        }
        var settings = AppSettings()
        settings.webhookURL = url
        settings.heartbeatSeconds = model.heartbeatSeconds
        settings.pollSeconds = model.pollSeconds
        settings.checkForUpdates = model.checkForUpdates
        settings.preReleases = model.preReleases
        settings.homeNetworks = networks
        settings.askForNewNetworks = model.askForNewNetworks
        settings.detectOtherCalls = model.detectOtherCalls
        settings.ignoredNetworks = model.ignoredNetworks
        onSave(settings, model.autostart)
    }
}
