# Übergabe: Netzfilter, Pause, Updater (Branch `network-pause`)

Arbeitsnotiz. **Vor dem Merge nach `main` löschen.**

`network-pause` = `main` (1.3.0) + die Netzfilter-/Pause-Commits aus `tray-apps`, neu
aufgesetzt am 13.11.2026. **`origin/tray-apps` nicht mehr verwenden:** veraltet und enthält
in 4bb7cb4 das Signaturzertifikat samt Passwort (öffentliches Repo) → Zertifikat ersetzen,
Branch löschen (Entscheidung beim User).

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
6. MessageBox erscheint im Vordergrund (TopMost-Owner) und blockiert den Tray nicht
   dauerhaft; keine zweite MessageBox, solange eine offen ist.
7. Außerhalb beenden → kein `offline` an HA (HA-Logbuch/Sensor bleibt bis Timeout).
8. Leeres Feld → Verhalten wie vorher.
9. **Senden pausieren** (Tray-Menü, Untermenü 1 Stunde / 8 Stunden / 1 Tag / Bis ich
   fortsetze; auf macOS ebenso, dort ebenfalls noch nicht durchgeklickt):
   - Pause → HA bekommt sofort `offline`, Menü „Home Assistant: pausiert bis …“ bzw.
     „pausiert“, Tooltip „… - pausiert“, „Senden fortsetzen“ sichtbar, danach nichts gesendet.
   - `%LOCALAPPDATA%\TeamsBusyLight\pause.txt` (UTC-Zeitstempel oder `always`); App beenden
     (kein `offline`, da pausiert) und neu starten → Pause bleibt.
   - „Senden fortsetzen“ → sofort gesendet, `pause.txt` weg. Abgelaufene Pause (zum Test
     Zeitstempel in `pause.txt` in die nahe Zukunft setzen und neu starten) endet von selbst.
10. **Version im Einstellungsfenster** unten links („Version 1.3.0“), auch im Installer
    (aus `version.txt` bzw. `manifest.json`); bei `0.0.0` wird nichts angezeigt.

Ergebnisse 13.11.2026 (Windows 11, PS 5.1):
- 1 ✅ Feld, Button, Checkbox, „Version 1.3.0“ im Installer; Registry `DisplayVersion` 1.3.0.
  Skalierung 125/150 % nicht geprüft.
- 2 ✅ `192.168.11.0/24`; `vEthernet (Default Switch)` hat kein Gateway → gefiltert.
- 3 ✅ Warnung, Fenster bleibt offen (Logik zusätzlich per Skript: `foo`, `10.1/16`,
  `1.2.3.4/33`, `/24`, `1.2.3.4/-1` abgelehnt).
- 4 ✅ Senden normal, Sensor aktuell.
- 5 ✅ nach Fix: **MessageBox mit `DefaultDesktopOnly` kam in der Tray-App nach 8 ms mit
  „Nein“ zurück, ohne angezeigt zu werden** (isoliert, auch im Timer und mit Launcher-Start,
  nicht reproduzierbar). Ohne die Option erschien sie, rutschte aber später hinter andere
  Fenster. Jetzt: unsichtbares TopMost-Owner-Fenster → Box TopMost und im Vordergrund.
  Ja/Nein/Abbrechen danach je ✅ (Liste, `IgnoredNetworks` ohne erneute Frage,
  `AskForNewNetworks: false`).
- 6 ✅ Tray/Timer läuft weiter, während die Box offen ist (Status wurde weiter geloggt).
- 7 ✅ außerhalb beendet → HA blieb `available`.
- 8 ✅ leeres Feld → Senden wie vorher.
- 9 ✅ 1 Stunde (sofort `offline`, `pause.txt` UTC), übersteht Neustart, läuft von selbst ab
  (`Sending resumed`, `available`), „Bis ich fortsetze“ + „Senden fortsetzen“.
- 10 ✅ (siehe 1).
- Offen: macOS-Pause noch nicht durchgeklickt; prüfen, ob `NSAlert` dort ähnlich betroffen ist
  (eher nicht).

## Danach: Windows-Signatur (Variante 1) und In-App-Updater (entschieden 13.11.2026)

Erst nach den Windows-Tests oben angehen. Der User hat Variante 1 gewählt: eigenes,
selbst erstelltes Zertifikat, Signieren in GitHub Actions, kein CA-Zertifikat (SignPath
Foundation / Azure Trusted Signing evtl. später, ändert am Updater nur den Fingerabdruck).

Ziel: Der Updater installiert nur Dateien, die mit **unserem** Zertifikat signiert sind
(Pinning des Fingerabdrucks bzw. Designated Requirement). Windows muss dem Zertifikat nicht
vertrauen. Kein stilles Update: Update-Hinweis bekommt „Jetzt aktualisieren“, Installation
erst nach Bestätigung.

### Windows-Signatur – umgesetzt (13.11.2026), Zertifikat/Secrets offen

Abweichend vom ersten Plan wird nicht jede `.ps1` signiert, sondern ein **Dateikatalog**
`TeamsBusyLight.cat` (`New-FileCatalog`, SHA-256) über **alle** Dateien des Downloads – auch
`Launcher.cs` (wird zur exe kompiliert), `Install.cmd`, Übersetzungen, `version.txt`.
- `windows/tools/create-signing-certificate.ps1`: RSA 3072, 10 Jahre, PFX + Passwort + Base64
  nach `%USERPROFILE%	eams-busy-light-signing-windows` (Ziel im Repo wird abgelehnt, ACL nur
  für den Benutzer), gibt den SHA-256-Fingerabdruck aus, entfernt das Zertifikat aus dem Store.
- `windows/tools/build-release.ps1 -Version x`: Stage `dist/TeamsBusyLight-Windows` (ohne
  `tools`), `version.txt`, Katalog, Signatur mit DigiCert-Zeitstempel (3 Versuche, Pflicht),
  prüft Fingerabdruck gegen `$SigningCertificateSha256` und den fertigen Ordner, dann ZIP.
  Ohne Secret: unsigniert mit Warnung.
- `Common.ps1`: `$SigningCertificateSha256` (noch leer), `Test-TeamsReleaseSignature`
  (`SignedCms.CheckSignature($true)` statt Authenticode-Vertrauen, Pinning, `Test-FileCatalog`;
  gibt `$null` oder den Grund zurück).
- `release.yml`: neuer Job `windows` (windows-latest, PS 5.1) baut/signiert/lädt das ZIP hoch;
  `assets` nur noch macOS. Beide mit `environment: release`.
- `validate.yml`: Job „Build Windows download“ baut bei jedem Push mit den Secrets.
- Lokal getestet (Wegwerf-Zertifikat): sauber → OK; ohne/anderer Pin, geänderte/zusätzliche
  Datei, gekipptes Katalog-Byte, fehlender Katalog, neu signiert mit gleichnamigem fremdem
  Zertifikat → abgelehnt. `Get-AuthenticodeSignature` = `UnknownError` (erwartet).

- `Import-TeamsSecurityModule`: lädt `Microsoft.PowerShell.Security` aus `$PSHOME`; sonst
  scheitert PS 5.1, wenn `PSModulePath` von PowerShell 7 geerbt ist (z. B. aus Git Bash oder
  einem PS-7-Terminal gestartet: „AuditToString is already present“).

Erledigt am 13.11.2026 (User-Entscheidung):
- Echtes Zertifikat auf dem Windows-PC erzeugt: `%USERPROFILE%	eams-busy-light-signing-windows`
  (ACL nur Sebastian), SHA-256 `C490C7763D8BB1C4098F00D45BB87C7BC45A41282686F89D32C941EBDBABF48F`
  in `Common.ps1`. Lokaler Build damit signiert und gegen den Pin geprüft.
- Environment `release`: Pflicht-Freigabe (Reviewer `sebastianschmalzbauer` – das `gh`-Konto;
  `SebastianInTheWild` wurde von der API nicht übernommen), nur Tags `v*.*.*`.
  Secrets `WINDOWS_SIGNING_PFX`/`_PASSWORD` dort gesetzt.
- `validate.yml` ohne Signatur-Secrets (Windows unsigniert, macOS ad hoc); Release bricht ab,
  wenn ein Signatur-Secret fehlt.

- macOS-Secrets vom User ins Environment verschoben (12:43 UTC), Repo-Secrets gelöscht –
  auf Repo-Ebene gibt es keine Secrets mehr.

Offen (User): Backup der Windows-PFX
an einem sicheren Ort (Passwortmanager); geht sie verloren, braucht es ein neues
Zertifikat und alle Installationen müssen einmal von Hand aktualisiert werden.

### Updater Windows – umgesetzt und getestet (13.11.2026)

- `TeamsBusyLight.ps1`: Update-Check merkt sich die Asset-URL von `TeamsBusyLight-Windows.zip`
  (nur `https://` und nur mit gepinntem Fingerabdruck), Menü/Balloon „Version x
  installieren …“ → Rückfrage (Ja/Nein, `Show-TeamsMessageBox`) → `GetByteArrayAsync` (Timer
  pollt) → `Install-TeamsUpdate`: `%TEMP%\TeamsBusyLight-Update-<guid>`, `Expand-TeamsZip`
  (kein Pfad außerhalb, max. 50 MB), `Test-TeamsReleaseSignature`, `version.txt` muss genau
  der angebotenen Version entsprechen (kein Unterschieben älterer signierter Releases),
  `Unblock-File`, startet `Install.ps1 -Quiet` mit **Arbeitsverzeichnis = Update-Ordner**
  (sonst blockiert das geerbte cwd `ProgramDir` dessen Löschung). Beim Beenden fürs Update
  kein `offline`. Endet der Installer und die App läuft noch → Fehlermeldung. Fehler →
  Meldung + Log, Ordner weg, alte Version läuft. Alte Update-Ordner (>10 min) beim Start weg.
- `Install.ps1 -Quiet`: nur als Update (sonst Fehler), kein Dialog, Einstellungen/Autostart
  bleiben, keine Admin-Schritte, keine Abschlussmeldung, Log „Updated to version x“.
- `Show-TeamsMessageBox` (Common.ps1) ersetzt das TopMost-Owner-Fenster der Netz-Frage.
- Test auf dem PC mit lokalem Fake-GitHub (127.0.0.1, installierte Kopie umgebogen), ZIP mit
  echtem Zertifikat signiert: 1.3.0 → 1.3.1 ✅ in 2 s, Einstellungen erhalten, HA ohne
  `offline`. Manipulierte `Launcher.cs` → abgelehnt ✅. Echtes 1.3.1 als „1.3.2“ angeboten →
  abgelehnt ✅. `Install.ps1 -Quiet` aus dem Repo ✅. Danach saubere Installation (1.3.0).
- Nicht getestet: echter Download von GitHub (Redirect auf objects.githubusercontent.com) –
  beim ersten echten Release prüfen. Hinweis: Versionen ≤ 1.3.0 haben noch keinen Updater;
  das erste Update auf die Version mit Updater läuft noch per `Install.cmd`.

### Updater macOS
- ZIP laden, entpacken (`ditto -x -k`), mit `SecStaticCodeCheckValidity` gegen die
  Designated Requirement der laufenden App prüfen (`certificate leaf = H"…"`); nur bei
  Erfolg `~/Applications/Teams Busy Light.app` ersetzen (über temporären Namen, dann
  Austausch) und per `open -n` neu starten, alte Instanz beendet sich (sendet `offline`).
- Ad-hoc-signierte Builds (ohne Zertifikat) bieten keinen Update-Knopf.
- Freigaben (Festplattenvollzugriff) bleiben, da gleiches Zertifikat – nach dem ersten
  echten Update prüfen.

### Doku
README (beide), CHANGELOG, Hinweis zum Environment `release` und zur Freigabe beim Release.

## Windows-Grundtests (UAC, Update vom Dienst, Deinstallation) – erledigt

Am 13.11.2026 auf `main` durchgeführt, alle ✅ (Details im Commit 3df82e5), danach Release 1.3.0.
Windows 10 entfällt (ohne Support).

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
