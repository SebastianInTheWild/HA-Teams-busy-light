# Changelog

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
