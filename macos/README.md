# Teams Busy Light for macOS

A menu bar app that sends the status of the new Microsoft Teams client on macOS to the
**Teams Busy Light** integration in Home Assistant. It is the macOS counterpart of the
[Windows app](../windows/README.md) and uses the same integration, sensors and blueprint.

## What is detected

| Sensor | Source on macOS |
|--------|-----------------|
| `status` (`available`, `busy`, `do_not_disturb`, `be_right_back`, `away`, `offline`, …) | The Teams logfile (`MSTeams_*.log`). The Mac client logs the presence with English values in every app language, so no language setting is needed |
| `activity` (`in_call` / `not_in_call`) | The power assertion `Microsoft Teams Call in progress` that Teams holds during a call (as shown by `pmset -g assertions`) |
| `offline` | Teams is not running, or the Mac is off / asleep (integration timeout) |

> [!NOTE]
> Ringing (incoming/outgoing call) is not detected separately on macOS; the activity
> switches to `in_call` as soon as the call starts.

## Requirements

* macOS 13 Ventura or newer with the new Microsoft Teams ("Microsoft Teams (work or school)")
* Home Assistant reachable from the Mac
* The **Teams Busy Light** integration installed in Home Assistant

## Setup in Home Assistant

Add the integration once per Mac user: Settings → Devices & Services → Add Integration →
**Teams Busy Light**. Enter a name, e.g. `Mac` → `sensor.teams_mac_status` /
`sensor.teams_mac_activity`, and copy the webhook URL shown after setup (also available
later under **Configure**).

## Installation on the Mac

No administrator rights are needed. Download `TeamsBusyLight-macOS.zip` from the
[latest release](https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest),
unzip it and run in Terminal, in that folder:

```shell
bash install.sh
```

The installer copies `Teams Busy Light.app` to `~/Applications` and starts it. The app

* shows the Teams status in the menu bar,
* opens its settings on the first start – paste the webhook URL and click **Send Test**,
* starts after every login (LaunchAgent `com.teamsbusylight.agent`, can be turned off in
  the settings).

**Two permissions are needed:**

* **Full Disk Access:** the Teams logs are stored in the protected data of the Teams app,
  and current macOS versions do not offer a prompt for it. The app shows the steps: it
  opens System Settings → Privacy & Security → Full Disk Access and a Finder window with
  the app, which you drag into the list and turn on. The app notices the access by itself.
  The settings window shows whether the access is granted.
* **Find devices on your local network:** macOS asks when the app first contacts Home
  Assistant in your network; click Allow.

The app is signed with the same certificate in every release, so the access is kept
after updates. To update, run `install.sh` of the new release; the settings are kept.
The script version (1.2.0 and older) is replaced, and its webhook URL and intervals are
taken over.

Without a release download (e.g. a clone of the repository), `install.sh` builds the app
with `build.sh`; this needs the Xcode Command Line Tools (`xcode-select --install`).

### Menu bar icon

Like the tray icon on Windows: the Teams Busy Light icon with a colored dot.

| Dot | Meaning |
|-----|---------|
| green | Available |
| red | Busy, in a meeting, presenting, focusing, do not disturb, or in a call |
| yellow | Away, be right back |
| gray | Offline (Teams not running) |
| none | Status unknown |

The menu shows the details, including a missing webhook URL, an unreachable Home
Assistant or missing access to the Teams logs.

### Settings

Open **Settings…** in the menu (or double-click the app in `~/Applications`):

| Setting | Default | Meaning |
|---------|---------|---------|
| Webhook URL | – | Webhook URL of the integration entry; **Send Test** sends the current status |
| Keep-alive | 60 s | Must be shorter than the offline timeout of the integration (default 180 s) |
| Check Teams | 2 s | Check interval |
| Start at login | on | Start the app after login |
| Check for updates daily | on | Shows a menu entry and a notification when a new release is available; the update itself is downloaded from the release page |

The app sends `offline` when it is quit and before the Mac goes to sleep.

## Verification

* The menu shows the detected status, the call state and when the status was last sent.
* Show what is detected right now (nothing is sent; run from Terminal the access to the
  Teams logs belongs to Terminal, so it may show `no access to the logs`):
  ```shell
  ~/Applications/Teams\ Busy\ Light.app/Contents/MacOS/TeamsBusyLight --show
  ```
* Log with every change (**Show Log** in the menu): `~/Library/Logs/TeamsBusyLight.log`
  ```shell
  tail -f ~/Library/Logs/TeamsBusyLight.log
  ```
* Send a status manually to test the connection:
  ```shell
  ~/Applications/Teams\ Busy\ Light.app/Contents/MacOS/TeamsBusyLight --set-status busy
  ```

## Troubleshooting

* **`Permission denied` for `~/Library/LaunchAgents`:** the folder was created by another
  installer (e.g. a VPN client) as `root`. Fix it once, then run the installer again:
  ```shell
  sudo chown "$(whoami)" ~/Library/LaunchAgents
  ```
* **"No access to the Teams logs":** click the entry in the menu or **Grant…** in the
  settings, or add `~/Applications/Teams Busy Light.app` under System Settings → Privacy &
  Security → Full Disk Access yourself (press `cmd`+`shift`+`G` to enter the path).
* **No icon in the menu bar:** on a Mac with a notch, icons that do not fit next to the
  notch are hidden. Remove other icons or use a menu bar manager; the settings open
  when you double-click the app in `~/Applications`.
* **Menu shows "Home Assistant: not reachable":** the reason is shown when you point at
  the entry. Check that "Teams Busy Light" is allowed under System Settings → Privacy &
  Security → Local Network.
* **`Unknown Teams presence: …` in the log:** Teams logged a value the app does not
  know yet. Please [open an issue](https://github.com/SebastianInTheWild/HA-Teams-busy-light/issues/new/choose)
  with that value.

## Building

```shell
bash macos/build.sh
```

builds a Universal app (Apple silicon and Intel) into `macos/build`. Without signing
settings it is signed ad hoc; macOS then asks for the access again after every build.
`create-signing-certificate.sh` creates the self-signed certificate once; the release
workflow signs with it from the secrets `MACOS_SIGNING_P12` and `MACOS_SIGNING_PASSWORD`
(see the script for local signing).

## Uninstall

```shell
bash uninstall.sh
```

Quits and removes the app, the LaunchAgent, the settings, the log and the granted access.
The Home Assistant integration entry is not changed.
