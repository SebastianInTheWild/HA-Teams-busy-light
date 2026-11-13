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
    @Published var homeNetworks: String
    @Published var askForNewNetworks: Bool
    let ignoredNetworks: String
    @Published var testing = false
    @Published var testResult: (text: String, ok: Bool)?
    @Published var error: String?
    /// nil while Teams is not running (the access is only checked then)
    @Published var logAccess: Bool?

    init(settings: AppSettings, autostart: Bool) {
        webhookURL = settings.webhookURL
        heartbeatSeconds = settings.heartbeatSeconds
        pollSeconds = settings.pollSeconds
        self.autostart = autostart
        checkForUpdates = settings.checkForUpdates
        homeNetworks = settings.homeNetworks
        askForNewNetworks = settings.askForNewNetworks
        ignoredNetworks = settings.ignoredNetworks
    }
}

/// Settings window: webhook URL with test, intervals, start at login and
/// update hint
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// Current status and call state, sent by "Send Test"
    let currentStatus: () -> (status: String?, inCall: Bool)
    let onSave: (AppSettings, Bool) -> Void
    let onClose: () -> Void
    let onGrantAccess: () -> Void
    let version: String

    private var trimmedURL: String {
        model.webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
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
                    Stepper(L.heartbeat(model.heartbeatSeconds), value: $model.heartbeatSeconds, in: 10...3600, step: 10)
                    Stepper(L.poll(model.pollSeconds), value: $model.pollSeconds, in: 1...60)
                } footer: {
                    hint(L.heartbeatHint)
                }

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

                Section {
                    Toggle(L.autostart, isOn: $model.autostart)
                    Toggle(L.checkForUpdates, isOn: $model.checkForUpdates)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

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
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
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
            return
        }
        let networks = model.homeNetworks.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalid = HomeNetwork.parse(networks).invalid {
            model.error = L.invalidNetwork(invalid)
            return
        }
        var settings = AppSettings()
        settings.webhookURL = url
        settings.heartbeatSeconds = model.heartbeatSeconds
        settings.pollSeconds = model.pollSeconds
        settings.checkForUpdates = model.checkForUpdates
        settings.homeNetworks = networks
        settings.askForNewNetworks = model.askForNewNetworks
        settings.ignoredNetworks = model.ignoredNetworks
        onSave(settings, model.autostart)
    }
}
