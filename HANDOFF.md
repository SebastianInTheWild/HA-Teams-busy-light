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

Windows-Doku (`windows/README.md`, Haupt-README, CHANGELOG) am 13.11.2026 aktualisiert.

## Stand macOS (`macos/`) – gebaut und lokal teilweise getestet (12.11.2026)

Erledigt: `app/main.swift` (AppDelegate, Statusleiste, Edit-Hauptmenü, Sleep/Wake, SIGTERM →
sauberes Beenden mit `offline`, `--show`, `--set-status`, Update-Benachrichtigung über
UserNotifications), `app/SettingsView.swift` (SwiftUI-Form; `ObservableObject` statt `@State`,
weil `@State` im macOS-27-SDK ein Makro ist und die Command Line Tools das SwiftUI-Makro-Plugin
nicht mitliefern), `build.sh` (Universal, Icon, Signatur per `MACOS_SIGNING_P12`/`_PASSWORD`
über temporäre Keychain, sonst `SIGNING_IDENTITY` oder ad-hoc), `install.sh`/`uninstall.sh`
neu, `create-signing-certificate.sh` (3DES-PKCS#12, damit `security import` es liest),
CI-Jobs (`validate.yml` „Build macOS app“, `release.yml` „assets“ mit beiden ZIPs),
`macos/README.md`, macOS-Teile im Haupt-README, CHANGELOG. `teams-busy-light.sh` und
`settings.sh` gelöscht.

Lokal getestet (macOS 27, nur CLT): Build (x86_64-Linkerwarnung zu
`libswiftCompatibilityPacks.a` ist harmlos), `--show`, Start, LaunchAgent wird geschrieben und
bei verschobener App umgeschrieben, SIGTERM sendet `offline`, `install.sh` mit Migration aus
`settings.sh` und als Update, Senden an lokalen Test-Webhook, Signatur mit Testzertifikat →
Designated Requirement `certificate leaf = H"…"` (stabil).

Nach dem Test mit dem User (12./13.11.2026) ergänzt:
- „Daten anderer Apps“ wird auf macOS 27 nicht abgefragt (`tccd`: „Denied (Service Policy)“,
  auch fürs Terminal). Nötig ist Festplattenvollzugriff. Die App zeigt den Hinweis beim Start
  selbst an, öffnet Einstellungen und Finder (App markiert, zum Hineinziehen), erkennt die
  Freigabe ohne Neustart (Mitteilung „Zugriff erteilt“), und das Einstellungsfenster zeigt
  den Zugriffsstatus mit „Freigeben …“.
- Menüleisten-Icon wie unter Windows: Brand-Icon mit farbigem Punkt (gleiche RGB-Werte).
  Das orange Fehler-Icon ist entfallen; Fehler stehen im Menü.
- Fester Bedienungshilfen-Name „Teams Busy Light“ und `autosaveName`: Menüleisten-Manager
  erkennen Icons am Namen; vorher wechselte er mit dem Status. Thaw zeigte das Icon trotzdem
  nicht an (wohl Altlasten der früheren Namen), Hidden Bar zeigt es richtig an.
- Freigabe bleibt über Neubauten erhalten, wenn mit demselben Zertifikat signiert wird
  (lokal mit Testzertifikat geprüft).

Offen:
- `uninstall.sh` testen.
- Echtes Zertifikat erzeugen und Secrets setzen (User).
- CI-Jobs laufen erst nach dem Push.

## Neu (13.11.2026): „Nur in diesen Netzen senden“ – auf Windows testen

Wunsch des Users: Unterwegs soll nichts an Home Assistant gehen, auch wenn die Webhook-URL
von außen erreichbar ist. Umgesetzt auf beiden Plattformen (macOS gebaut und Logik getestet,
Windows nur unter pwsh auf dem Mac: Parser ok, Netzfunktionen ok; **UI und Tray ungetestet**).

Verhalten:
- Einstellung **„Nur in diesen Netzen senden“** (CIDR-Liste, Komma/Semikolon/Leerzeichen,
  IPv4 und IPv6). Leer = überall senden (bisheriges Verhalten, Standard).
- Gesendet wird nur, wenn eine aktive Schnittstelle (nicht Loopback) eine Adresse in einem der
  Netze hat. Außerhalb: kein Senden, auch kein `offline` beim Beenden/Ruhezustand; Menü zeigt
  „Home Assistant: pausiert (nicht im Heimnetz)“; HA setzt nach dem Offline-Timeout (180 s)
  selbst `offline`. Zurück im Netz → sofort senden.
- Button **„Aktuelles Netz hinzufügen“**: IPv4-Netze aktiver Schnittstellen mit Gateway
  (Windows) bzw. ohne Point-to-Point/VPN (macOS), ohne 169.254.
- **Rückfrage bei neuem Netz** (Schalter „Bei einem neuen Netz fragen …“, Standard an): nur
  wenn Netze eingetragen sind und der Rechner außerhalb ist. Windows: MessageBox
  Ja = hinzufügen, Nein = merken (`IgnoredNetworks`, nicht erneut fragen), Abbrechen = Frage
  abschalten. macOS: NSAlert „Hinzufügen“/„Nicht hinzufügen“ + Checkbox „Nicht mehr fragen“.
- Einschränkung (dem User nennen/ist im Hint klar): Hat ein fremdes Netz denselben Bereich
  (z. B. Hotel mit 192.168.178.0/24 wie die FritzBox), wird dort gesendet. VPN ins Heimnetz
  zählt als Heimnetz (gewollt).
- Settings-Keys: Windows `HomeNetworks`, `AskForNewNetworks`, `IgnoredNetworks` in
  `settings.json`; macOS `homeNetworks`, `askForNewNetworks`, `ignoredNetworks`.
- Code: `windows/Common.ps1` (Abschnitt „Send only in these networks“, Dialogfeld),
  `windows/TeamsBusyLight.ps1` (`Update-TeamsNetworkState` alle 5 s, `Request-TeamsNewNetwork`),
  `macos/app/HomeNetwork.swift`, `TeamsMonitor.swift` (`awayFromHome`, `onAway`),
  `main.swift` (`offerNewNetwork`).

Testplan Windows (Ergebnisse hier eintragen):

1. `windows\Install.cmd` (Update der bestehenden Installation): Einstellungsfenster zeigt das
   neue Feld, Button und Checkbox; Layout ok (nichts abgeschnitten, auch bei 125/150 % Skalierung).
2. „Aktuelles Netz hinzufügen“ → richtiges Netz (z. B. `192.168.x.0/24`), kein VPN-/Hyper-V-/
   WSL-Netz. Falls vEthernet-Adapter (Hyper-V/WSL) mit Gateway auftauchen: filtern.
3. Ungültige Eingabe (`foo`, `10.1/16`, `1.2.3.4/33`) → Warnung, Fenster bleibt offen.
4. Mit eigenem Netz gespeichert: Senden normal, Sensor in HA aktuell.
5. Nur ein fremdes Netz eintragen (z. B. `10.99.0.0/16`) → innerhalb 5 s Menü „pausiert“,
   Log „Nicht im Heimnetz …“, MessageBox zum aktuellen Netz:
   - Ja → Netz in der Liste, Senden läuft wieder (Menü „gesendet um …“).
   - Nein (nach Zurücksetzen) → keine erneute Frage, `IgnoredNetworks` in settings.json.
   - Abbrechen → `AskForNewNetworks: false`, Checkbox in den Einstellungen aus.
6. MessageBox erscheint im Vordergrund (`DefaultDesktopOnly`) und blockiert den Tray nicht
   dauerhaft; keine zweite MessageBox, solange eine offen ist.
7. Außerhalb beenden → kein `offline` an HA (HA-Logbuch/Sensor bleibt bis Timeout).
8. Leeres Feld → Verhalten wie vorher.
9. Danach weiter mit dem Windows-Testplan unten.

## Nächster Schritt: Windows-Tests (auf dem Windows-PC)

macOS ist fertig und vom User getestet. Auf Windows noch ungetestet: UAC-Pfade,
Update vom alten Dienst, Deinstallation mit Hosts-Eintrag und Altdienst. Testplan (Ergebnisse hier eintragen):

1. **Altinstallation vorbereiten:** Ordner `windows` von Tag `v1.2.0`
   (`git worktree add ../tbl-1.2.0 v1.2.0`) mit dessen `Install.cmd` installieren → Dienst
   `Microsoft Teams Status Monitor` läuft, `C:\Scripts\TeamsStatus\Settings.ps1` enthält
   die URL.
2. **Update vom Dienst:** `windows\Install.cmd` aus `tray-apps` (ohne Admin starten).
   Erwartet: URL vorausgefüllt, Hinweis auf Entfernen des Dienstes, eine UAC-Abfrage,
   danach Dienst und `C:\Scripts\TeamsStatus` weg, Tray-App läuft, Sensor in HA aktuell.
3. **Hosts-Eintrag:** Installer erneut, Haken „Hosts-Datei“ setzen → UAC → Zeile mit
   `# Teams Busy Light` in `%windir%\System32\drivers\etc\hosts`.
4. **UAC ablehnen:** Installer mit Hosts-Haken, UAC mit „Nein“ → Warnung
   „nicht ausgeführt: Hosts-Eintrag“, Installation trotzdem vollständig.
5. **Deinstallation über „Installierte Apps“** (Grundfall am 12.11. getestet, alles
   entfernt; offen nur der Hosts-Teil): Abfrage, Hosts-Frage (Ja → UAC → Zeile
   weg), danach weg: Autostart (`HKCU\...\Run`), Startmenü, Eintrag in „Installierte
   Apps“, `%LOCALAPPDATA%\Programs\TeamsBusyLight`, `%LOCALAPPDATA%\TeamsBusyLight`;
   HA bekommt `offline`.
6. **Deinstallation mit `Uninstall.ps1`** aus dem Download-Ordner (gleiche Prüfungen),
   dabei einmal mit noch vorhandenem Altdienst (Frage nach dessen Entfernung).
7. **Release-Layout:** Ordner `windows` + `version.txt` (z. B. `1.2.0`) kopieren und
   daraus installieren → Update-Hinweis nur bei neuerer Version.
8. Optional Windows 10 (README nennt 10 oder 11, getestet nur 11).

## Später: Musik am Rechner während Anrufen pausieren (Wunsch des Users, zurückgestellt am 13.11.2026)

Läuft am Rechner Musik (Spotify, Apple Music, Browser …), wird sie bei einem Anruf pausiert
und danach fortgesetzt, aber nur, wenn die App sie selbst pausiert hat. Schalter
„Musik während Anrufen pausieren“ in den Einstellungen, beide Plattformen.
- Windows: Auslöser schon beim Klingeln; Steuerung über
  `GlobalSystemMediaTransportControlsSessionManager` (WinRT), keine Berechtigung nötig.
- macOS: Auslöser erst bei Anrufbeginn (Klingeln nicht erkennbar). Keine offizielle
  app-übergreifende API: entweder MediaRemote (privat, kann mit Updates brechen) oder
  AppleScript pro App (Music, Spotify; Automation-Abfrage). Mit dem User entscheiden.

## Testen auf dem Mac

- `bash macos/build.sh && open "macos/build/Teams Busy Light.app"`
- `"macos/build/Teams Busy Light.app/Contents/MacOS/TeamsBusyLight" --show`
- Test-Webhook lokal: `python3 -m http.server` reicht nicht (POST) – kleiner Handler oder
  echten HA-Webhook eines Test-Integrationseintrags nehmen.
- Beim ersten Start fragt macOS nach „Daten anderer Apps“ und „lokales Netzwerk“.
