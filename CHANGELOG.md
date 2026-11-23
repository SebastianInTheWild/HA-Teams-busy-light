# Changelog

## 1.7.1

* Windows: the camera now comes from the sensor activity monitor of Windows (the source of the camera privacy indicator, Windows 10 1903 and newer) and is reported with the app using it. Before, newer Windows 11 versions showed it off all the time: old registry entries from before an upgrade hid the newer source, and the events of the camera service do not tell on and off apart for Teams. Also works with virtual cameras that use a real camera (tested with the Insta360 virtual camera)
* Windows: **Copy diagnostics** shows the app using the camera

## 1.7.0

* Releases: every merge into `main` publishes a release, every push to another branch a pre-release (`<version>-beta.<n>`) once the version is bumped; a release is published only with both app downloads attached
* macOS and Windows: "Update channel" in the settings (General): Release or Beta (pre-releases); back on Release with a pre-release installed, the app offers to switch to the latest release
* Windows: a download attached to a release after the update check is now picked up on the next check (before, only a restart of the app did)
* Integration: an app of a pre-release (e.g. `1.7.0-beta.3`) is not reported as outdated by integration `1.7.0`
* Integration: an invalid message to the webhook is answered with "Invalid message" only; the details are in the Home Assistant log

## 1.6.0

* Integration: every change of the status or the call activity fires the event `teams_status_changed` with the device ID
* Blueprint: select only the Teams device instead of the status and activity sensors ("Run actions" applies the current status); needs this integration version. Existing automations from the blueprint must select the device once after re-importing

## 1.5.1

* macOS and Windows: "Check for updates" in the menu and in the settings (General): asks right away, also when the daily check is off, and says whether a newer version is available; from the menu it offers to install it

## 1.5.0

* macOS and Windows: camera and microphone in use by any app are sent to Home Assistant (new `binary_sensor.…_camera` and `binary_sensor.…_microphone`); optional "Also detect calls in other apps" (on by default) reports a call while any app uses the microphone (Zoom, Webex, FaceTime, browser …). Windows: the microphone comes from the audio system and works on all versions; on newer Windows 11 versions, which no longer report the camera in the registry, it comes from the events of the camera service (experimental)
* macOS and Windows: settings window in tabs (General, Detection, Networks)
* macOS and Windows: set a status from the menu instead of the Teams status (30 minutes, 1 or 2 hours, or until reset); Home Assistant shows `source: manual`
* macOS and Windows: "Copy diagnostics" in the settings window (without the webhook ID)
* Integration: the apps send their version and platform; the device shows the app version, and an outdated app raises a repair issue
* Integration: tests with pytest-homeassistant-custom-component in CI

## 1.4.0

* macOS and Windows: optional "Send only in these networks" (e.g. `192.168.1.0/24`): outside these networks nothing is sent to Home Assistant, even if the webhook URL is reachable from outside; asks whether to add a new network (can be turned off)
* macOS and Windows: pause sending from the menu (1 hour, 8 hours, 1 day or until resumed); Home Assistant gets `offline` once
* macOS and Windows: the settings window shows the installed version
* Windows: install updates from the app ("Install version …" in the menu or the notification): after confirmation it downloads the release, checks the signature of all files against the project's own certificate and installs it; settings are kept and Home Assistant gets no `offline` in between
* macOS: install updates from the app ("Install version …" in the menu or the notification): after confirmation it downloads the release, installs it only if it is signed with the same certificate as the installed app, and restarts; settings and Full Disk Access are kept, Home Assistant gets no `offline` in between
* macOS: "Access granted" goes to the Notification Center only (no dialog)
* Windows: the download contains a catalog of all its files, signed with the project's own certificate

## 1.3.0

* Windows: tray app per user instead of the Windows service; no administrator rights needed (only for the optional hosts file entry). Status icon in the notification area, settings window (webhook URL with test, intervals, Teams language, start at sign-in), Start menu and "Installed apps" entry. The installer takes over the webhook URL and removes the service of earlier versions
* Windows: umlauts in the German texts fixed (translations are now JSON files)
* Windows: the release contains `TeamsBusyLight-Windows.zip`
* macOS: native menu bar app instead of the script; same status icon as on Windows, settings window (webhook URL with test, intervals, start at login), guides through granting Full Disk Access, sends `offline` when quitting or going to sleep. `install.sh` takes over the settings of the script version
* macOS: the release contains the signed app (`TeamsBusyLight-macOS.zip`); granted permissions are kept after updates
* macOS and Windows: optional daily check for a new release, shown in the menu (no automatic installation)
* Blueprint: optionally play music or radio on a media player; stop during calls and while offline

## 1.2.0

* macOS support: `macos/install.sh` installs a background app that sends the Teams status and call state to the integration; no administrator rights needed
* Windows: `Install.cmd` starts the installer as administrator without a PowerShell console
* Windows: installer window and taskbar show the current Teams Busy Light icon
* Integration: the webhook URL uses the address Home Assistant is currently opened with (e.g. the local address) instead of always the external URL

## 1.1.2

* Brand icon: red dot in the corner shows the busy light

## 1.1.1

* Brand icon resized to 256×256 (`icon.png`) and 512×512 (`icon@2x.png`), shown in Home Assistant and HACS
* Requires Home Assistant 2026.3.0 or newer (local brand icons)
* README: link to the HACS installation guide

## 1.1.0

* Windows: new `Uninstall.ps1` removes the Teams status service and the installed files
* Windows: installer and messages in German and English, several Windows users per computer
* Integration: "Teams" is added to the entered name automatically; entity IDs always use English names
* Blueprint: sensors have no fixed default, triggers only react to known states
* Updated brand icon

## 1.0.0

* Home Assistant integration **Teams Busy Light** (config flow, webhook, status and activity sensors, German/English translations, offline timeout, brand icon)
* Windows script: Teams language detected automatically (German, English), language-neutral states, keep-alive, webhook instead of access token
* Blueprint **Teams Busy Light**: only the lights have to be selected
