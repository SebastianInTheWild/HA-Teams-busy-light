# Übergabe: Anrufe anderer Apps, Kamera/Mikrofon, eigener Status, Diagnose, HA-Reparaturen

Arbeitsnotiz für den Branch `call-detection` (ab `main` = 1.4.0, begonnen 13./14.11.2026).
**Vor dem Merge nach `main` löschen.** Version (`manifest.json`) und Release erst auf
Anweisung des Users; CHANGELOG unter „Unreleased“ ist gepflegt. Geplant: 1.5.0.

## Stand 16.11.2026 (Vormittag)

Erledigt heute: Windows-Mikrofon über WASAPI (`287f389`), Windows-Kamera über
Kameradienst-Ereignisse, experimentell (`0ebf86f`), HA-Test ✅ (siehe „Testplan Home
Assistant“), Windows 6 (eigener Status wird gesendet, `source: manual`) ✅.

**HA läuft gerade mit der Integration aus dem Branch** (manuell kopiert per SSH
`hassio@192.168.11.252`, Schlüssel `~/.ssh/claude_ha`, `sudo` nötig; `manifest.json` dort auf
1.5.0 gesetzt, im Repo nicht). Sicherung der alten: `/config/teams_status.bak-1.4.0` →
nach dem Release über HACS auf 1.5.0 und die Sicherung löschen.

Noch offen vor Release: Windows 8 (Beenden → `offline`), 9 (CPU), Store-App/mehrere Apps
gleichzeitig nur vor Ort; Mac: Tabs ansehen, Teams-Anruf, Schalter aus, „Hey Siri“.
Frage an User offen: neue Windows-Binärsensoren haben Bereichs-Präfix (`buro_…`) –
umbenennen?

## Stand 14.11.2026 – weiter am Montag, 16.11.2026

Letzter Commit: `86a47b3` (gepusht). User will 1.5.0 releasen, sobald die Tests durch sind.
Mac: getestet bis auf die Punkte unten. Windows: per RDP getestet (keine echte Kamera/Mikro).
HA: noch **nichts** getestet.

**Reihenfolge am Montag:**
1. **HA-Test** (wichtigster offener Block, geht per HACS an alle): Integration aus dem
   Branch nach `/config/custom_components/teams_status` kopieren, HA neu starten, dann
   „Testplan Home Assistant“ unten. Auf dem HA heißen die bestehenden Entities
   `sensor.teams_sebastian_windows_{status,activity}` und `sensor.teams_mac_{status,activity}`
   – prüfen, wie die neuen Binärsensoren tatsächlich heißen (Testplan nennt
   `binary_sensor.teams_camera`, vermutlich mit Gerätenamen davor). Automation
   `automation.teams_busy_light` ist aktuell aus.
2. **Windows neu installieren** (`windows\Install.cmd`) – die laufende Installation hat den
   „ohne .exe“-Fix aus `86a47b3` noch nicht. Dann offene Windows-Punkte (per RDP möglich):
   - 6: eigener Status wird nach Fortsetzen wirklich gesendet (HA `…_status`, `source: manual`);
     „Bis ich ihn zurücksetze“ + Neustart bleibt; Ablauf von selbst (`manual-status.txt`).
   - 8: Beenden → `offline` mit Kamera/Mikro aus in HA.
   - 9: CPU-Last der Tray-App (Task-Manager, einige Minuten).
   - Pause ist aufgehoben (16:08); vor Tests prüfen, dass `pause.txt` nicht wieder gesetzt ist.
3. **Mac** (optional vor Release): Einstellungen mit Tabs ansehen (User), Teams-Anruf,
   Schalter „andere Anrufe“ aus, „Hey Siri“.
4. **Nach dem Release möglich:** echte Kamera/Mikrofon an Windows (vor Ort, nicht per RDP),
   Store-App-Pfad (z. B. Windows-Kamera-App).

**Release 1.5.0 (wenn der User es sagt):** Version in `manifest.json` auf 1.5.0, CHANGELOG
„Unreleased“ → 1.5.0 (Einträge aus `86a47b3` ergänzen: Desktop-Apps ohne .exe,
Diagnose-Beschriftungen, Einstellungen in Tabs), diese Datei löschen, nach `main` mergen,
Release wie bei 1.4.0 (Windows-Download per bash hochladen, signiert). Danach auf dem HA
über HACS auf das Release 1.5.0 zurück und den Reparatur-Hinweis mit einer alten App prüfen.

## Befund 16.11.2026: Registry-Erkennung unter Windows 11 26H2 wirkungslos

Echter Test per RDP (Kamera und Mikrofon umgeleitet): Kamera-App, Sprachrekorder und Edge →
nichts erkannt. `ConsentStore\{webcam,microphone}` enthält nur noch `Value`/`LastSetTime`,
**kein** `LastUsedTimeStart/Stop` (auch keine alten Einträge, `NonPackaged` ohne
Unterschlüssel). Nutzung steht jetzt in
`C:\ProgramData\Microsoft\Windows\CapabilityAccessManager\CapabilityAccessManager.db` –
nur für SYSTEM lesbar. Der Test vom 14.11. lief nur, weil die Einträge künstlich angelegt
waren. Vorschlag an den User: Mikrofon über WASAPI (`IAudioSessionManager2`, aktive
Aufnahme-Sitzungen mit Prozess-ID, ohne Admin), Kamera: Registry nur als Rückfall für ältere
Windows-Versionen, sonst nicht verfügbar (README). Erst Prototyp auf dem Rechner, dann Einbau.

**Umgesetzt (16.11.):** Mikrofon über WASAPI (`Get-TeamsMicrophoneUsers`, C# per `Add-Type`,
einmal ~200 ms, danach ~3 ms je Prüfung), Registry nur noch Rückfall. Kamera: unbekannt
(`$null`), wenn Windows keine `LastUsedTimeStart` mehr schreibt → wird nicht gesendet, HA
bleibt „unbekannt“, auch bei `offline` (`Get-TeamsOfflineExtra`). Diagnose zeigt die Quelle.
Echter Test per RDP ✅: Sprachrekorder („VoiceRecorder“) und Edge („msedge“) an/aus, HA
`in_call`/`not_in_call` passend.

**Kamera (16.11., User: Variante 1 = experimentell in 1.5.0, keine neue Einstellung – gleich
wie Mac):** Ereignis-Kanal `Microsoft-Windows-MF-FrameServer/Camera_FrameServer` (für
normale Benutzer lesbar, kein dokumentiertes An/Aus). Watchdog-Ereignis 11, TimerScope 2 =
Kamera-Gerät: Vorgang 2 = Stream startet, 3 = Stream endet; je Geräte-Objekt (Property 1)
zählt das neueste, an = irgendein Objekt zuletzt 2. Dienst `FrameServer` beendet → aus.
Kanal aus/fehlt → `$null` (unbekannt). `Get-TeamsCameraFromEvents`, `EventLogReader`
rückwärts, 30 Ereignisse, ~5 ms. Kein App-Name → Log „Kamera in Benutzung“ (neuer Text
`LogCameraOnNoApp`). Diagnose zeigt die Kamera-Quelle.
Test per RDP ✅: Kamera-App an/aus, Edge an/aus (kurzes Aus, wenn die Seite den Stream
selbst neu startet – echt, kein Fehler). Zwei Apps gleichzeitig mit RDP-Kamera nicht
testbar (die Kamera bedient nur eine App; Edge bekam sie erst nach Schließen der
Kamera-App). **Vor Ort mit echter Kamera prüfen:** gleiche Ereignisse? Zwei Apps gleichzeitig?

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

Ergebnisse 14.11.2026:
- Installation aus dem Branch ✅ (Dateien identisch mit dem Branch).
- 1 Einstellungen (alter Stand **ohne** Tabs, `4951b61`): Checkbox mit Hinweis, „Diagnose
  kopieren“ neben „Test senden“, Layout ✅.
- 1 Tab-Version (`fdd6e63`) installiert, Einstellungen mit Tabs sehen gut aus ✅ (User).
- 2–5 (Kamera/Mikrofon) mit echten Geräten offen: User nur per RDP am Windows-Rechner.
  Ersatz: künstlicher Eintrag `ConsentStore\{webcam,microphone}\NonPackaged\C:#Test#FakeCall.exe`
  (Start gesetzt, Stop = 0) → Log „Camera in use: FakeCall.exe“, „Microphone in use:
  FakeCall.exe“, `activity: in_call` in HA ✅; Stop gesetzt → beides aus, `not_in_call` ✅.
  Einträge danach gelöscht. Store-App-Pfad (ohne `NonPackaged`) nicht simuliert.
  Desktop-Apps jetzt ohne „.exe“ (Wunsch User): „FakeZoom.EXE“ → „FakeZoom“ ✅.
- 6 Status festlegen (Nicht stören, 30 Min) ✅ geloggt; Senden nicht geprüft (Pause aktiv).
  „Wieder Teams-Status verwenden“ ✅ (16:08 „Manual status ended, using the Teams status“).
  Offen: Senden, „Bis ich ihn zurücksetze“ + Neustart, Ablauf von selbst.
- Hinweis: Datumsangaben im Log („until 11/14/2026 4:36 PM“) im US-Format (`ToString('g')`,
  wie schon bei der Pause) – kosmetisch, nicht geändert.
- 7 Diagnose ✅ (Webhook-ID entfernt). Beschriftungen geklärt (Mac und Windows):
  „Sent:“ → „Effective:“ (zeigt, was gesendet würde, auch bei Pause), „Other calls:
  detected/ignored“ → „on/off“.
- 8 Pause + eigener Status: Pause gewinnt, nichts gesendet ✅. Beenden → `offline` offen.
- `offline` trotz laufendem Teams korrekt: in Teams „Offline anzeigen“ gesetzt.

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

Ergebnisse 16.11.2026 (HA 2026.10.x, Integration aus `0ebf86f` mit Version 1.5.0):
- Lädt ohne Fehler; Neustart ~25 s.
- 1 Neue Entities ✅: Windows `binary_sensor.buro_teams_sebastian_windows_{camera,microphone}`
  (HA setzt bei neuen Entities den Bereich „Büro“ davor; ältere Sensoren ohne), Mac
  `binary_sensor.teams_mac_{camera,microphone}`; vor der ersten Nachricht `unknown`, danach
  `off`.
- 2 Attribute ✅ `source: manual`, `app_version: 1.4.0`, `platform: windows`; Gerät zeigt
  `sw_version` 1.4.0.
- 3 Reparatur ✅ `outdated_app_<entry>` für DESKTOP-HB92PQU und FWYL2G2GKF (Mac),
  „1.4.0 < 1.5.0“, Link aufs Release.
- Nebenbei (nicht unsere): Spook meldet seit dem Neustart unbekannte `sensor.agent_*` im
  Dashboard „Agenten“.

## Offen / später

- Blueprint: optional Kamera als Auslöser (z. B. „rot nur bei Kamera an“) – nur Beispiel im
  README, Blueprint unverändert.
- Musik während Anrufen pausieren (zurückgestellt).
- Aus der letzten Übergabe: `origin/tray-apps` enthält das alte Zertifikat samt Passwort
  (öffentlich) → ersetzen und Branch löschen (User); PFX/p12 sichern; erster echter
  In-App-Update-Download von GitHub (Redirect) mit dem nächsten Release prüfen.
- macOS: Pause „Bis ich fortsetze“ und Mitteilungen (für die App gesperrt) prüfen.
