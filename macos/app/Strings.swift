import Foundation

/// UI texts in German or English, following the preferred language of macOS.
enum L {
    static let german = Locale.preferredLanguages.first?.hasPrefix("de") ?? false

    private static func t(_ en: String, _ de: String) -> String {
        german ? de : en
    }

    static func statusName(_ status: String?) -> String {
        switch status {
        case "available": return t("Available", "Verfügbar")
        case "busy": return t("Busy", "Beschäftigt")
        case "in_a_call": return t("In a call", "Im Anruf")
        case "in_a_meeting": return t("In a meeting", "In einer Besprechung")
        case "presenting": return t("Presenting", "Präsentiert")
        case "focusing": return t("Focusing", "Konzentriert")
        case "do_not_disturb": return t("Do not disturb", "Nicht stören")
        case "be_right_back": return t("Be right back", "Bin gleich zurück")
        case "away": return t("Away", "Abwesend")
        case "offline": return t("Offline", "Offline")
        default: return t("Unknown", "Unbekannt")
        }
    }

    static func activityName(inCall: Bool) -> String {
        inCall ? t("In a call", "Im Anruf") : t("Not in a call", "Kein Anruf")
    }

    // Menu
    static func menuStatus(_ name: String) -> String { "Teams: \(name)" }
    static func menuActivity(_ name: String) -> String { t("Call: \(name)", "Anruf: \(name)") }
    static func menuSentAt(_ time: String) -> String {
        t("Home Assistant: sent at \(time)", "Home Assistant: gesendet um \(time)")
    }
    static let menuSendFailed = t("Home Assistant: not reachable", "Home Assistant: nicht erreichbar")
    static let menuNotConfigured = t("Home Assistant: webhook URL missing", "Home Assistant: Webhook-URL fehlt")
    static let menuNoLogAccess = t("No access to the Teams logs", "Kein Zugriff auf die Teams-Logs")
    static let menuSettings = t("Settings…", "Einstellungen …")
    static let menuShowLog = t("Show Log", "Log anzeigen")
    static let menuQuit = t("Quit Teams Busy Light", "Teams Busy Light beenden")
    static func menuUpdate(_ version: String) -> String {
        t("Update \(version) available…", "Update \(version) verfügbar …")
    }
    static let checkForUpdates = t("Check for updates daily", "Täglich nach Updates suchen")

    // Settings
    static let settingsTitle = t("Teams Busy Light Settings", "Teams Busy Light – Einstellungen")
    static let webhook = t("Webhook URL", "Webhook-URL")
    static let webhookHint = t(
        "Shown in Home Assistant after adding the Teams Busy Light integration, later under Configure.",
        "Wird in Home Assistant nach dem Hinzufügen der Integration Teams Busy Light angezeigt, später unter Konfigurieren."
    )
    static func heartbeat(_ seconds: Int) -> String {
        t("Keep-alive every \(seconds) s", "Lebenszeichen alle \(seconds) s")
    }
    static let heartbeatHint = t(
        "Must be shorter than the offline timeout of the integration (default 180 s).",
        "Muss kürzer sein als das Offline-Timeout der Integration (Standard 180 s)."
    )
    static func poll(_ seconds: Int) -> String {
        t("Check Teams every \(seconds) s", "Teams prüfen alle \(seconds) s")
    }
    static let autostart = t("Start at login", "Bei der Anmeldung starten")
    static let test = t("Send Test", "Test senden")
    static let testing = t("Sending…", "Wird gesendet …")
    static func testOk(_ status: String) -> String {
        t("Sent: \(status). Check the sensor in Home Assistant.", "Gesendet: \(status). Prüfe den Sensor in Home Assistant.")
    }
    static func testFailed(_ reason: String) -> String { t("Failed: \(reason)", "Fehlgeschlagen: \(reason)") }
    static let save = t("Save", "Sichern")
    static let cancel = t("Cancel", "Abbrechen")
    static let invalidWebhook = t(
        "Enter a valid HTTP or HTTPS webhook URL ending with /api/webhook/<id>.",
        "Gib eine gültige HTTP- oder HTTPS-Webhook-URL ein, die auf /api/webhook/<id> endet."
    )
    static func autostartFailed(_ reason: String) -> String {
        t("Start at login could not be changed: \(reason)", "Start bei der Anmeldung konnte nicht geändert werden: \(reason)")
    }
    static let noLogAccessHint = t(
        "Teams Busy Light cannot read the Teams logs. Allow access to data from other apps, or add ~/Applications/Teams Busy Light.app under System Settings > Privacy & Security > Full Disk Access.",
        "Teams Busy Light kann die Teams-Logs nicht lesen. Erlaube den Zugriff auf Daten anderer Apps oder füge ~/Applications/Teams Busy Light.app unter Systemeinstellungen > Datenschutz & Sicherheit > Festplattenvollzugriff hinzu."
    )
}
