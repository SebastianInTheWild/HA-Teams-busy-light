# Übergabe: Anrufe anderer Apps, Kamera/Mikrofon, eigener Status, Diagnose, HA-Reparaturen

Arbeitsnotiz für den Branch `call-detection` (ab `main` = 1.4.0, begonnen 13./14.11.2026).
**Vor dem Merge nach `main` löschen.** Version (`manifest.json`) und Release erst auf
Anweisung des Users; CHANGELOG unter „Unreleased“ ist gepflegt. Geplant: 1.5.0.

## Entscheidungen (mit dem User, 13.11.2026)

- Gewünscht: (1) Teams-Mikro/Kamera, (2) Anrufe anderer Apps, (3) eigenen Status im Menü
  setzen, Diagnose-Knopf, HA-Seite.
- (1) Die lokale Teams-Schnittstelle („API für Drittanbieter-Apps“, Port 8124) hat Microsoft
  zum 30.06.2026 abgeschaltet (MC1266901); beim User nicht mehr vorhanden. Ersatz: „Kamera an“
  und „Mikrofon in Benutzung“ aus dem Betriebssystem, für jede App. „Mikro stumm“ und „Hand
  gehoben“ gibt es damit nicht.
- HA-Seite: **kein** Hinweis, wenn ein Rechner lange nichts gesendet hat (User: irrelevant).
  Nur: App-Version am Gerät, Reparatur-Hinweis bei veralteter App.

## Umsetzung

Nachricht der Apps (neu, alte Apps senden die Felder nicht, HA bleibt kompatibel):
`camera` (bool), `microphone` (bool), `source` (`teams`/`manual`), `app_version`,
`platform` (`windows`/`macos`). Mit `offline` (Beenden, Pause, Ruhezustand) gehen
`camera`/`microphone` = false mit.

**Integration** (`custom_components/teams_status`):
- `binary_sensor.py`: `binary_sensor.teams_camera`, `binary_sensor.teams_microphone`
  (englische Namen wie die Sensoren, Restore, beim Timeout → off).
- Status-Sensor: Attribute `source`, `app_version`, `platform`.
- `app_version` → `sw_version` des Geräts; älter als die Integration → Reparatur
  `outdated_app_<entry_id>` (Warnung, Link aufs Release), verschwindet bei neuer Version,
  beim Entfernen des Eintrags. `0.0.0` (Build aus dem Repo) und Unsinn → kein Hinweis.
- Geräte-Lookup über `dr.async_entries_for_config_entry` (`async_get_device(identifiers=…)`
  ist ab HA 2026.10 veraltet und warf im Test einen Fehler).
- `tests/` + `pytest.ini`: 5 Tests (alte App-Nachricht, neue Felder, ungültige Werte,
  Reparatur, Timeout). Lokal ✅ gegen HA 2026.2.3 (Py 3.13) und 2026.10.4 (Py 3.14), auch mit
  `-W error::DeprecationWarning`. Neuer CI-Job „Integration tests“ (Python 3.14).

**macOS** (`macos/app`):
- `DeviceUsage.swift`: Mikrofon pro Prozess (`kAudioProcessPropertyIsRunningInput`, ab
  macOS 14.2, liefert App-Namen), sonst Geräte-Flag; Kamera über CoreMediaIO
  `kCMIODevicePropertyDeviceIsRunningSomewhere`. Keine Berechtigungsabfrage.
  Wichtig: Teams bringt das virtuelle Gerät „Microsoft Teams Audio“ (Ein- **und** Ausgang)
  mit – mit dem reinen Geräte-Flag zählte schon ein Klingelton als Mikrofon. Darum pro
  Prozess. Audiowiedergabe (`afplay`) → Mikrofon bleibt aus ✅.
- `TeamsMonitor`: `teamsInCall`, `camera`, `microphone`, `microphoneUsers`, `manual`,
  `effectiveStatus`, `inCall` = Teams-Anruf oder (Einstellung an und Mikrofon). Gesendet
  wird bei jeder Änderung von Status/Aktivität/Kamera/Mikro/Quelle (`sentKey`).
- Menü „Status festlegen“ → Verfügbar/Beschäftigt/Nicht stören/Bin gleich zurück/Abwesend →
  30 Min/1 Std/2 Std/Bis ich ihn zurücksetze; „Wieder Teams-Status verwenden“. Gespeichert in
  den Defaults (`manualStatus`, `manualStatusUntil`), übersteht Neustart, läuft ab.
  Statuszeile „Teams: Beschäftigt (manuell bis 15:30)“, Anrufzeile bei anderer App
  „Anruf: Im Anruf (Mikrofon: zoom.us)“.
- Einstellungen: Schalter „Auch Anrufe in anderen Apps erkennen“ (Standard an), Knopf
  „Diagnose kopieren“ (`Diagnostics.swift`, Webhook-ID wird entfernt, auch in Logzeilen).
- `--show` zeigt Kamera/Mikrofon.

**Windows** (`windows/`):
- `Common.ps1`: `Get-TeamsDeviceUsage`/`Get-TeamsDeviceUsers` lesen
  `HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\{webcam,microphone}`
  (Store-Apps direkt, Desktop-Apps unter `NonPackaged`, Pfad mit `#`): in Benutzung, wenn
  `LastUsedTimeStart` ≠ 0 und `LastUsedTimeStop` = 0. Keine Berechtigung nötig.
  `Get/Set-TeamsManualStatus` (`%LOCALAPPDATA%\TeamsBusyLight\manual-status.txt`,
  „<status> <UTC|always>“), Einstellung `DetectOtherCalls`, `Start-TeamsStatusSend -Extra`,
  `app_version`/`platform` in jeder Nachricht, `$OfflineExtra`. Einstellungsdialog:
  Checkbox + Hinweis „Auch Anrufe in anderen Apps erkennen“, Knopf „Diagnose kopieren“
  (nur in der Tray-App, nicht im Installer) rechts neben „Test senden“.
- `TeamsBusyLight.ps1`: `$State.TeamsActivity`/`Camera`/`Microphone`/`MicrophoneApps`/`Manual`,
  `SentKey`; `Get-TeamsEffectiveStatus`, `Set-/Clear-TeamsManualState`,
  `Get-TeamsDiagnostics`; Menü „Status festlegen“ + „Wieder Teams-Status verwenden“.
- Übersetzungen de/en ergänzt.
- Auf dem Mac mit `pwsh` geprüft: Parser aller Skripte ✅, eigener Status speichern/lesen/
  „always“/kaputte Datei/entfernen ✅, Standard `DetectOtherCalls` ✅, Nachricht mit allen
  Feldern an lokalen Test-Webhook ✅, Texte ✅. **Registry-Erkennung, Menü, Dialog,
  Zwischenablage nur auf Windows testbar.**

## Testplan macOS (Ergebnisse eintragen)

App läuft im Test aus `~/Applications`; Webhook ggf. auf echten HA zurückstellen.
1. Photo Booth (oder FaceTime) öffnen → Log „Camera on“, „Microphone in use by …“; Menü
   „Anruf: Im Anruf (Mikrofon: Photo Booth)“; Nachricht `camera: true`, `microphone: true`,
   `activity: in_call`. Schließen → alles aus.
2. Teams-Anruf: Menü „Anruf: Im Anruf“ (ohne Klammer, da Teams-Anruf).
3. Schalter „Auch Anrufe in anderen Apps erkennen“ aus → Photo Booth: Mikrofon `true`,
   `activity: not_in_call`.
4. Musik/Video abspielen → Mikrofon bleibt aus. Diktierfunktion/Siri: prüfen, ob „Hey Siri“
   dauerhaft als Mikrofon zählt (falls ja: Prozesse wie `corespeechd` ausfiltern).
5. Status festlegen → Beschäftigt → 30 Min: Statuszeile „(manuell bis …)“, Icon rot,
   `source: manual`; „Wieder Teams-Status verwenden“ → Teams-Status, `source: teams`.
   „Bis ich ihn zurücksetze“ + Neustart → bleibt.
6. Diagnose kopieren → Text einfügen: keine Webhook-ID, Werte plausibel.
7. Einstellungsfenster: Layout ok, nichts abgeschnitten.

Ergebnisse 14.11.2026:
- 1 Kamera (Photo Booth) an/aus ✅ sofort gemeldet (`camera: true/false`). Mikrofon blieb aus –
  korrekt, Photo Booth nutzt es erst bei Videoaufnahme. Mikrofon ✅: „Sprachmemos“ und
  „Microsoft Teams ModuleHost“ (Teams-Vorschau/Gerätetest, kein Teams-Anruf) erkannt,
  `activity: in_call`, danach wieder aus; Kamera auch nach dem Ruhezustand ✅.
  Nicht geprüft: „Hey Siri“ (2–4), Teams-Anruf (2), Schalter aus (3).
- 7 Einstellungsfenster war zu hoch (User) → Tabs „Allgemein“ (Zugriff, Webhook, Autostart,
  Updates), „Erkennung“ (andere Anrufe, Intervalle, Diagnose), „Netze“; Fenster 520 × 449 pt.
  Fehler beim Sichern springen auf den passenden Tab. Vom User noch anzusehen.
- 5 eigener Status 30 Min ✅ (`source: manual`), „Wieder Teams-Status verwenden“ ✅.
- 6 Diagnose ✅ (Webhook-ID entfernt, Werte plausibel).
- Behoben: Bei Kamera-/Mikrofonwechsel stand zusätzlich eine unveränderte „Status: …“-Zeile
  im Log; jetzt nur bei geänderter Status-/Aktivitätszeile (Mac und Windows).

## Testplan Windows (Ergebnisse eintragen)

Vorbereitung: Branch `call-detection` holen, `windows\Install.cmd` (Update der Installation).
1. Einstellungen jetzt in Tabs wie am Mac (`TabControl`, auf dem Mac nicht darstellbar,
   **ungetestet**): „Allgemein“ (Webhook + Test, Autostart, Updates; im Installer zusätzlich
   Hosts-Eintrag), „Erkennung“ (andere Anrufe, Intervalle, Teams-Sprache, Diagnose kopieren),
   „Netze“. Prüfen: nichts rechts abgeschnitten (Seitenbreite fest = Tab-Breite − 8 px),
   Höhe passt zum höchsten Tab, Seitenhintergrund ok, bei 100/125/150 %. Fehler beim
   Sichern springen auf den Tab (ungültige URL → Allgemein, ungültiges Netz → Netze).
   Installer: Hinweiskarten über den Tabs, **kein** Diagnose-Knopf. Test senden, Aktuelles
   Netz hinzufügen, Diagnose kopieren funktionieren.
2. Kamera-App öffnen → Log „Kamera in Benutzung: …“ (App-Name plausibel? Store-App z. B.
   `Microsoft.WindowsCamera`), Sensor in HA an. Schließen → aus.
3. Mikrofon: Sprachrekorder oder Zoom/Webex/Browser (z. B. Teams im Browser, Meet) →
   „Mikrofon in Benutzung: …“, Menü „Anruf: Im Anruf (Mikrofon: …)“, HA `in_call`.
   Desktop-App (NonPackaged) und Store-App je einmal.
4. Teams-Anruf: Aktivität aus Teams (auch `incoming_call` beim Klingeln), Mikro zusätzlich an.
5. Checkbox aus → Mikrofon an, Aktivität `not_in_call`.
6. Status festlegen (alle Dauern, „Bis ich ihn zurücksetze“ + Neustart,
   `manual-status.txt`), „Wieder Teams-Status verwenden“, Ablauf von selbst (Zeitstempel in
   der Datei auf nahe Zukunft setzen, neu starten).
7. Diagnose kopieren → einfügen: keine Webhook-ID, Teams-Version, Netze, Logzeilen.
8. Pause + eigener Status: Pause gewinnt (nichts gesendet); Beenden → `offline` mit
   Kamera/Mikro aus.
9. CPU-Last der Tray-App bei 2-s-Prüfung unverändert niedrig (Registry wird jedes Mal gelesen).

## Testplan Home Assistant

Neue Integration auf den HA bringen: `custom_components/teams_status` aus dem Branch per
Samba/SSH nach `/config/custom_components/teams_status` kopieren (HACS bietet nur Releases
und den Standard-Branch an); HA neu starten. Nach dem Test über HACS wieder auf das Release
zurück.
1. Bestehender Eintrag: neue Entities `binary_sensor.teams_camera`/`_microphone`
   (bei App 1.4.0 „unbekannt“), keine Fehler im Log.
2. Neue App: Gerät zeigt Firmware/Version, Attribute `source`, `app_version`, `platform`.
3. Reparatur: alte App (1.4.0) meldet sich → Hinweis unter Einstellungen → Reparaturen,
   sobald die Integration eine höhere Version hat (erst mit der 1.5.0-Versionsnummer
   sichtbar; zum Testen vorher `manifest.json` lokal auf 1.5.0 setzen).

## Offen / später

- Blueprint: optional Kamera als Auslöser (z. B. „rot nur bei Kamera an“) – nur Beispiel im
  README, Blueprint unverändert.
- Musik während Anrufen pausieren (zurückgestellt).
- Aus der letzten Übergabe: `origin/tray-apps` enthält das alte Zertifikat samt Passwort
  (öffentlich) → ersetzen und Branch löschen (User); PFX/p12 sichern; erster echter
  In-App-Update-Download von GitHub (Redirect) mit dem nächsten Release prüfen.
- macOS: Pause „Bis ich fortsetze“ und Mitteilungen (für die App gesperrt) prüfen.
