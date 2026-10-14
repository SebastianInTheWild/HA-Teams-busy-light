# Teams Busy Light for macOS

Sends the status of the new Microsoft Teams client on macOS to the **Teams Busy Light**
integration in Home Assistant. It is the macOS counterpart of the
[Windows script](../windows/README.md) and uses the same integration, sensors and blueprint.

## What is detected

| Sensor | Source on macOS |
|--------|-----------------|
| `status` (`available`, `busy`, `do_not_disturb`, `be_right_back`, `away`, `offline`, …) | The Teams logfile (`MSTeams_*.log`). The Mac client logs the presence with English values in every app language, so no language setting is needed |
| `activity` (`in_call` / `not_in_call`) | The power assertion `Microsoft Teams Call in progress` that Teams holds during a call (`pmset -g assertions`) |
| `offline` | Teams is not running, or the Mac is off / asleep (integration timeout) |

> [!NOTE]
> Ringing (incoming/outgoing call) is not detected separately on macOS; the activity
> switches to `in_call` as soon as the call starts.

## Requirements

* macOS with the new Microsoft Teams ("Microsoft Teams (work or school)")
* Home Assistant reachable from the Mac
* The **Teams Busy Light** integration installed in Home Assistant

## Setup in Home Assistant

Add the integration once per Mac user: Settings → Devices & Services → Add Integration →
**Teams Busy Light**. Enter a name, e.g. `Mac` → `sensor.teams_mac_status` /
`sensor.teams_mac_activity`, and copy the webhook URL shown after setup (also available
later under **Configure**).

## Installation on the Mac

No administrator rights are needed. Download the `macos` folder and run in Terminal, in
that folder:

```shell
bash install.sh
```

The installer asks for the webhook URL and

* copies the script and `settings.sh` to `~/Library/Application Support/TeamsBusyLight`,
* creates the small background app `~/Applications/Teams Busy Light.app` (no Dock icon,
  with the Teams Busy Light icon from `icon.png`) that runs the script,
* starts it now and after every login (LaunchAgent `com.teamsbusylight.agent`).

**macOS asks twice for "Teams Busy Light" – click Allow both times:**

* **Access data from other apps:** the Teams logs are stored in the protected data of the
  Teams app; the access is granted only to this app, not to Terminal or bash.
* **Find devices on your local network:** needed to reach Home Assistant in your network.

Run `bash install.sh` again to update the script or change the URL (press Enter to keep
it). Your `settings.sh` and the granted access are kept.

### Settings

`~/Library/Application Support/TeamsBusyLight/settings.sh`:

| Variable | Default | Meaning |
|----------|---------|---------|
| `HA_WEBHOOK_URL` | – | Webhook URL of the integration entry (set by the installer) |
| `HEARTBEAT_SECONDS` | `60` | Keep-alive interval |
| `POLL_SECONDS` | `2` | Check interval |

After changing settings, run `bash install.sh` again to restart.

## Verification

* Show what is detected right now (nothing is sent):
  ```shell
  bash ~/Library/Application\ Support/TeamsBusyLight/teams-busy-light.sh --show
  ```
* Log with every change: `~/Library/Logs/TeamsBusyLight.log`
  ```shell
  tail -f ~/Library/Logs/TeamsBusyLight.log
  ```
* Send a status manually to test the connection:
  ```shell
  bash ~/Library/Application\ Support/TeamsBusyLight/teams-busy-light.sh --set-status busy
  ```

## Troubleshooting

* **`Permission denied` for `~/Library/LaunchAgents`:** the folder was created by another
  installer (e.g. a VPN client) as `root`. Fix it once, then run the installer again:
  ```shell
  sudo chown "$(whoami)" ~/Library/LaunchAgents
  ```
* **Log shows `Status: none` or `Cannot read the Teams logs`:** the app has no access to
  the Teams data. Add `~/Applications/Teams Busy Light.app` under System Settings →
  Privacy & Security → Full Disk Access (press `cmd`+`shift`+`G` to enter the path), then
  run `bash install.sh` again.
* **Log shows `Failed to send status to Home Assistant`:** check that "Teams Busy Light"
  is allowed under System Settings → Privacy & Security → Local Network.
* **`Unknown Teams presence: …` in the log:** Teams logged a value the script does not
  know yet. Please [open an issue](https://github.com/SebastianInTheWild/HA-Teams-busy-light/issues/new/choose)
  with that value.

## Uninstall

```shell
bash uninstall.sh
```

Removes the app, the LaunchAgent, the installed files, the log and the granted access.
The Home Assistant integration entry is not changed.
