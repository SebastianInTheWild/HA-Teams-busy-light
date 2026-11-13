# Changelog

## Unreleased

* macOS and Windows: optional "Send only in these networks" (e.g. `192.168.1.0/24`): outside these networks nothing is sent to Home Assistant, even if the webhook URL is reachable from outside; asks whether to add a new network (can be turned off)
* macOS and Windows: pause sending from the menu (1 hour, 8 hours, 1 day or until resumed); Home Assistant gets `offline` once
* macOS and Windows: the settings window shows the installed version

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
