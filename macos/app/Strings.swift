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
    static let menuAway = t("Home Assistant: paused (not in a home network)", "Home Assistant: pausiert (nicht im Heimnetz)")
    static let menuPausedAlways = t("Home Assistant: paused", "Home Assistant: pausiert")
    static func menuPausedUntil(_ time: String) -> String {
        t("Home Assistant: paused until \(time)", "Home Assistant: pausiert bis \(time)")
    }
    static let menuPause = t("Pause Sending", "Senden pausieren")
    static let pauseHour = t("For 1 Hour", "1 Stunde")
    static let pause8Hours = t("For 8 Hours", "8 Stunden")
    static let pauseDay = t("For 1 Day", "1 Tag")
    static let pauseAlways = t("Until Resumed", "Bis ich fortsetze")
    static let menuResume = t("Resume Sending", "Senden fortsetzen")
    static let menuConnecting = t("Home Assistant: connecting…", "Home Assistant: wird verbunden …")
    static let menuNoLogAccess = t("No access to the Teams logs", "Kein Zugriff auf die Teams-Logs")
    static let menuSettings = t("Settings…", "Einstellungen …")
    static let menuShowLog = t("Show Log", "Log anzeigen")
    static let menuQuit = t("Quit Teams Busy Light", "Teams Busy Light beenden")
    static func menuUpdate(_ version: String) -> String {
        t("Update \(version) available…", "Update \(version) verfügbar …")
    }
    static func updateNotification(_ version: String) -> String {
        t("Teams Busy Light \(version) is available. Click to open the release page.",
          "Teams Busy Light \(version) ist verfügbar. Klicke, um die Release-Seite zu öffnen.")
    }
    static func menuInstallUpdate(_ version: String) -> String {
        t("Install Version \(version)…", "Version \(version) installieren …")
    }
    static func menuInstallingUpdate(_ version: String) -> String {
        t("Installing Version \(version)…", "Version \(version) wird installiert …")
    }
    static func updateNotificationInstall(_ version: String) -> String {
        t("Teams Busy Light \(version) is available. Click to install it.",
          "Teams Busy Light \(version) ist verfügbar. Klicke, um es zu installieren.")
    }
    static func updateConfirm(_ version: String) -> String {
        t("Install Teams Busy Light \(version) now?", "Teams Busy Light \(version) jetzt installieren?")
    }
    static let updateConfirmText = t(
        "The app quits briefly and restarts with the new version. Your settings and the access to the Teams logs are kept.",
        "Die App wird kurz beendet und startet mit der neuen Version neu. Deine Einstellungen und der Zugriff auf die Teams-Logs bleiben erhalten."
    )
    static let install = t("Install", "Installieren")
    static let later = t("Later", "Später")
    static let whatsNew = t("What's New", "Neuigkeiten")
    static func updateFailed(_ version: String, _ reason: String) -> String {
        t("Teams Busy Light \(version) could not be installed:\n\(reason)\n\nThe current version keeps running. You can download the new version from the release page.",
          "Teams Busy Light \(version) konnte nicht installiert werden:\n\(reason)\n\nDie bisherige Version läuft weiter. Die neue Version kannst du von der Release-Seite laden.")
    }
    static let openReleasePage = t("Open Release Page", "Release-Seite öffnen")
    static let checkForUpdates = t("Check for updates daily", "Täglich nach Updates suchen")

    // Settings
    static func version(_ version: String) -> String { "Version \(version)" }
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
    static let homeNetworks = t("Send only in these networks", "Nur in diesen Netzen senden")
    static let homeNetworksHint = t(
        "Optional, e.g. 192.168.1.0/24; separate several networks with commas. Outside these networks nothing is sent, not even through an externally reachable URL; Home Assistant sets Teams offline after its timeout. Empty = send everywhere.",
        "Optional, z. B. 192.168.1.0/24; mehrere Netze mit Komma trennen. Außerhalb dieser Netze wird nichts gesendet, auch nicht über eine von außen erreichbare URL; Home Assistant setzt Teams nach dem Timeout auf offline. Leer = überall senden."
    )
    static let askForNewNetworks = t("Ask when in a new network", "Bei einem neuen Netz fragen")
    static func newNetworkTitle(_ network: String) -> String {
        t("New network: \(network)", "Neues Netz: \(network)")
    }
    static let newNetworkText = t(
        "The Mac is in a network that is not in \"Send only in these networks\". Teams Busy Light sends nothing here. Add the network so the status is sent here as well?",
        "Der Mac ist in einem Netz, das nicht unter „Nur in diesen Netzen senden“ steht. Teams Busy Light sendet hier nichts. Netz hinzufügen, damit der Status auch hier gesendet wird?"
    )
    static let addNetwork = t("Add", "Hinzufügen")
    static let dontAddNetwork = t("Don't Add", "Nicht hinzufügen")
    static let dontAskAgain = t("Don't ask again (can be turned on in the settings)", "Nicht mehr fragen (in den Einstellungen wieder einschaltbar)")
    static let addCurrentNetwork = t("Add Current Network", "Aktuelles Netz hinzufügen")
    static let noCurrentNetwork = t("No active network found.", "Kein aktives Netz gefunden.")
    static func invalidNetwork(_ entry: String) -> String {
        t("\"\(entry)\" is not a valid network. Enter networks like 192.168.1.0/24.",
          "„\(entry)“ ist kein gültiges Netz. Gib Netze wie 192.168.1.0/24 ein.")
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
    static let openPrivacySettings = t("Open System Settings", "Systemeinstellungen öffnen")
    static let ok = t("OK", "OK")
    static let noLogAccessHint = t(
        """
        Teams Busy Light needs Full Disk Access to read the status from the Teams logs.

        1. Click "Open System Settings". Full Disk Access and a Finder window with Teams Busy Light open.
        2. Drag Teams Busy Light from the Finder window into the list (or click + and choose it).
        3. Turn it on. If macOS offers "Quit & Reopen", click "Later".

        Teams Busy Light notices the access by itself; no restart is needed.
        """,
        """
        Teams Busy Light braucht den Festplattenvollzugriff, um den Status aus den Teams-Logs zu lesen.

        1. Klicke auf „Systemeinstellungen öffnen“. Festplattenvollzugriff und ein Finder-Fenster mit Teams Busy Light öffnen sich.
        2. Ziehe Teams Busy Light aus dem Finder-Fenster in die Liste (oder klicke auf + und wähle es aus).
        3. Schalte es ein. Bietet macOS „Beenden & erneut öffnen“ an, klicke auf „Später“.

        Teams Busy Light erkennt die Freigabe von selbst, ein Neustart ist nicht nötig.
        """
    )
    static let accessGranted = t(
        "Access granted. Teams Busy Light now reads your Teams status.",
        "Zugriff erteilt. Teams Busy Light liest jetzt deinen Teams-Status."
    )
    static let logAccess = t("Access to the Teams logs", "Zugriff auf die Teams-Logs")
    static let logAccessOk = t("Granted", "Erteilt")
    static let logAccessMissing = t("Missing", "Fehlt")
    static let logAccessUnknown = t("Checked while Teams is running", "Wird geprüft, solange Teams läuft")
    static let grantAccess = t("Grant…", "Freigeben …")
}
