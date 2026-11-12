# Übergabe: Tray-/Menüleisten-Apps (Branch `tray-apps`)

Arbeitsnotiz für die Fortsetzung auf dem Mac. **Vor dem Merge nach `main` löschen.**

## Ziel (mit dem User abgestimmt, 12.11.2026)

- **Windows:** Tray-App pro Benutzer statt NSSM-Dienst (Variante B). Keine Admin-Rechte im
  Betrieb; UAC nur für optionalen Hosts-Eintrag und zum Entfernen des alten Dienstes.
- **macOS:** komplett native Swift-Menüleisten-App (ersetzt AppleScript-Wrapper und
  `teams-busy-light.sh`), Einstellungsfenster in SwiftUI.
- **Einstellungen (beide):** Webhook-URL, „Test senden“, Lebenszeichen- und Prüfintervall,
  Autostart-Schalter, „Täglich nach Updates suchen“. Windows zusätzlich Teams-Sprache.
- **Updates:** nur **Hinweis** (Menüeintrag + einmalige Benachrichtigung → Release-Seite),
  keine automatische Installation. Quelle: GitHub API `releases/latest`.
- **macOS-Signatur:** eigenes, selbst erstelltes Code-Signing-Zertifikat als GitHub-Secret,
  damit die Signatur über Builds stabil bleibt und macOS die Freigaben (Daten anderer Apps,
  lokales Netzwerk) nach Updates nicht erneut abfragt. Ohne Secret: ad-hoc als Fallback.
- Version (`manifest.json`, UZ-Regel gilt hier nicht, aber Release nur auf Anweisung) und
  Release erst, wenn der User es sagt. CHANGELOG unter „Unreleased“ pflegen.

## Stand Windows (`windows/`) – fertig und lokal getestet

| Datei | Zweck |
|---|---|
| `Common.ps1` | Pfade, Texte (JSON, explizit UTF-8), Settings, Autostart (HKCU Run), Erkennung, Senden (HttpClient, async), Versionsvergleich, Einstellungs-/Installerfenster |
| `TeamsBusyLight.ps1` | Tray-App: NotifyIcon mit Statuspunkt, Menü, Monitor-Timer, Update-Hinweis, Single-Instance (Mutex + Events `Local\TeamsBusyLight.*`); `-SetStatus`, `-Settings` |
| `Launcher.cs` | wird bei der Installation mit `csc.exe` (.NET Framework) zu `TeamsBusyLight.exe` kompiliert → startet PowerShell ohne Konsolenfenster |
| `Install.ps1` / `Install.cmd` | ohne Admin; Ziel `%LOCALAPPDATA%\Programs\TeamsBusyLight`, Daten `%LOCALAPPDATA%\TeamsBusyLight`; Startmenü, „Installierte Apps“, `version.txt` (aus `version.txt` im Download oder `manifest.json`), übernimmt URL aus altem `C:\Scripts\TeamsStatus\Settings.ps1` |
| `AdminTasks.ps1` | elevated: Hosts-Eintrag setzen/entfernen, alten Dienst + `C:\Scripts\TeamsStatus` entfernen |
| `Uninstall.ps1` | pro Benutzer, auch über „Installierte Apps“ |
| `Translations/{de,en}.json` | ersetzen die `.psd1` (die hatten unter PS 5.1 kaputte Umlaute, da UTF-8 ohne BOM) |
| `icon.ico`, `icon.png` | aus dem Brand-Icon erzeugt |

Entfernt: `Get-TeamsStatus.ps1`, `Settings.ps1`, `Messages.ps1`, `nssm.exe`, `*.psd1`.
Nebenbefund: Der alte Dienst lief als SYSTEM aus `C:\Scripts\TeamsStatus` ohne gehärtete
ACLs (normale Benutzer konnten die Skripte ändern) – entfällt mit der neuen Lösung.

Getestet (Windows 11, PS 5.1): Erkennung (Status/Sprache), Senden, Heartbeat, Test-Button,
Installer durchgeklickt, Beenden sendet `offline`, Update-Hinweis (1.0.0 → 1.2.0 erkannt).
`Uninstall.ps1` vom User über „Installierte Apps“ getestet, alles entfernt.
**Nicht getestet:** UAC-Pfade (Hosts, Altdienst-Entfernung).

Offen Windows: `windows/README.md` neu schreiben; Haupt-README Abschnitt Windows anpassen.

## Stand macOS (`macos/app/*.swift`) – teilweise geschrieben, NIE kompiliert

Fertig geschrieben (ungeprüft!): `Strings.swift` (de/en), `Settings.swift` (UserDefaults
`com.teamsbusylight.app`, Keys `webhookURL`, `heartbeatSeconds`, `pollSeconds`,
`checkForUpdates`; `LoginItem` = LaunchAgent `com.teamsbusylight.agent` mit
`open -g -a <App>`, ohne KeepAlive; `Log` → `~/Library/Logs/TeamsBusyLight.log`),
`TeamsMonitor.swift` (inkrementelles Lesen der Teams-Logs, Mapping wie bisher im Bash-Skript,
Anruf über `IOPMCopyAssertionsByProcess` / „Microsoft Teams Call in progress“, Senden per
URLSession, Pause/Resume für Ruhezustand, `describe()` für `--show`),
`UpdateChecker.swift`.

Noch zu schreiben:
1. `main.swift` / `AppDelegate`: `NSApplication` mit `.accessory`; `--show` vor dem App-Start
   ausgeben und beenden. **Hauptmenü mit Edit-Menü** (Ausschneiden/Kopieren/Einsetzen/Alles
   auswählen) setzen, sonst funktioniert ⌘V im Textfeld einer LSUIElement-App nicht.
   `LoginItem.enableOnFirstStart()`. Ohne URL → Einstellungen öffnen.
   `applicationShouldHandleReopen` → Einstellungen öffnen (Doppelklick auf die App).
   `NSWorkspace.willSleep/didWake` → `monitor.pause()/resume()`.
   Beenden: `applicationShouldTerminate` → `offline` senden (max. 3 s).
2. Statusleiste: `NSStatusItem` mit SF Symbols in Farbe (`paletteColors`):
   available `checkmark.circle.fill` grün; busy/in_a_call/in_a_meeting/presenting/focusing
   `circle.fill` rot; do_not_disturb `minus.circle.fill` rot; away/be_right_back
   `clock.fill` gelb; im Anruf `phone.circle.fill` rot; offline/unbekannt `circle` (Template);
   Sendefehler/keine URL/kein Log-Zugriff `exclamationmark.circle` orange.
   Menü: Status, Anruf, HA-Verbindung (deaktiviert), ggf. „Kein Zugriff auf die Teams-Logs“,
   ggf. Update-Eintrag, „Einstellungen …“ (⌘,), „Log anzeigen“, „Teams Busy Light beenden“ (⌘Q).
3. `SettingsView.swift`: SwiftUI `Form` (`.formStyle(.grouped)`, macOS 13) in einem
   `NSWindow`/`NSHostingView`; Felder wie oben; „Test senden“ sendet aktuellen Status an die
   eingegebene URL; Sichern → `AppSettings.save()`, `LoginItem.setEnabled`, `monitor.update`,
   `updateChecker.setEnabled`. Vor dem Anzeigen `NSApp.activate(ignoringOtherApps: true)`.
4. `macos/build.sh`: `xcrun swiftc -O -swift-version 5 -target {arm64,x86_64}-apple-macos13.0`,
   `lipo` zu Universal, Bundle `Teams Busy Light.app` (Executable `TeamsBusyLight`),
   Info.plist (`CFBundleIdentifier com.teamsbusylight.app`, `LSUIElement`,
   `LSMinimumSystemVersion 13.0`, `NSLocalNetworkUsageDescription`,
   `CFBundleShortVersionString` aus `manifest.json`), `AppIcon.icns` aus `macos/icon.png`,
   signieren: Identität aus Umgebungsvariable (CI) sonst `-` (ad-hoc).
5. `macos/install.sh` neu: App neben dem Skript (Release-ZIP) oder per `build.sh` bauen;
   alten LaunchAgent `bootout`, alte Prozesse beenden (`teams-busy-light.sh`, alte App);
   `settings.sh` → `defaults write com.teamsbusylight.app …` migrieren; bei alter
   AppleScript-App (`Contents/MacOS/applet`) `tccutil reset All com.teamsbusylight.app`;
   alte Dateien unter `~/Library/Application Support/TeamsBusyLight` löschen; App nach
   `~/Applications` kopieren (`ditto`), Quarantäne entfernen, `open`.
   Check auf nicht schreibbares `~/Library/LaunchAgents` beibehalten.
   `uninstall.sh`: zusätzlich `defaults delete com.teamsbusylight.app`.
   Danach `macos/teams-busy-light.sh` und `macos/settings.sh` löschen.
6. Signatur-Zertifikat: Skript zum Erzeugen (openssl, `extendedKeyUsage=codeSigning`, .p12),
   Secrets `MACOS_SIGNING_P12` (base64) + `MACOS_SIGNING_PASSWORD`; in CI temporäre Keychain,
   Import, `codesign --sign <SHA-1>`. Prüfen, dass `codesign -d -r-` eine stabile
   Designated Requirement (Zertifikat statt cdhash) zeigt.
7. CI: `validate.yml` + Job „Build macOS app“ (macos-latest, `build.sh`);
   `release.yml` + Job, der `TeamsBusyLight-macOS.zip` (App + install.sh + uninstall.sh +
   README) und `TeamsBusyLight-Windows.zip` (Ordner `windows` + `version.txt`) an das
   Release hängt. PSScriptAnalyzer meldet nur Warnungen (CI prüft Severity Error).
8. Doku: `macos/README.md`, Haupt-README, CHANGELOG „Unreleased“.

## Testen auf dem Mac

- `bash macos/build.sh && open "macos/build/Teams Busy Light.app"`
- `"macos/build/Teams Busy Light.app/Contents/MacOS/TeamsBusyLight" --show`
- Test-Webhook lokal: `python3 -m http.server` reicht nicht (POST) – kleiner Handler oder
  echten HA-Webhook eines Test-Integrationseintrags nehmen.
- Beim ersten Start fragt macOS nach „Daten anderer Apps“ und „lokales Netzwerk“.
