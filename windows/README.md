# Teams Busy Light for Windows

> [!NOTE]
> This solution only works for the new version of Microsoft Teams. You may want to consider [Get-MonitorStatus](https://github.com/EBOOZ/Get-MonitorStatus) in combination with this app as well.

A small app in the notification area of the taskbar that sends the status of the new
Microsoft Teams client to the **Teams Busy Light** integration in Home Assistant. It is the
Windows counterpart of the [macOS app](../macos/README.md) and uses the same integration,
sensors and blueprint.

It is a single program, `TeamsBusyLight.exe` (C#, .NET Framework 4.8, which ships with
Windows 10 and 11; source in [`app`](app)). It runs no scripts and starts no PowerShell.

## Introduction

We're working a lot at our home office these days. Several people already found solutions to make working in the home office more comfortable. One of these ways is to automate activities in your home automation system based on your status on Microsoft Teams.

Microsoft provides the status of your account that is used in Teams via the Graph API. To access the Graph API, your organization needs to grant consent for the organization so everybody can read their Teams status. Since my organization didn't want to grant consent, I needed to find a workaround, which I found in monitoring the Teams client logfile for certain changes.

## What is detected

| Sensor | Source on Windows |
|--------|-------------------|
| `status` (`available`, `busy`, `in_a_call`, `in_a_meeting`, `presenting`, `focusing`, `do_not_disturb`, `be_right_back`, `away`, `offline`) | The taskbar icon overlay that Teams writes to its logfile (`MSTeams_*.log`) |
| `activity` (`not_in_call`, `in_call`, `incoming_call`, `outgoing_call`) | The call events in the same logfile, including ringing |
| `offline` | Teams is not running, or the PC is off / asleep (integration timeout) |

The states are language-neutral; Home Assistant shows them translated (German/English).

### Language of the Teams app

On Windows, Teams writes the status in the language of the app. [`app/StatusPatterns.cs`](app/StatusPatterns.cs) contains
the patterns per language (currently German and English). By default the language is
detected automatically; it can be set in the settings.

## Requirements

* Windows 11 with the new Microsoft Teams (Windows 10 is no longer supported by Microsoft
  and is not tested; the app will probably work there)
* Home Assistant reachable from the PC
* The **Teams Busy Light** integration installed in Home Assistant

## Setup in Home Assistant

Add the integration once per Windows user: Settings → Devices & Services → Add Integration →
**Teams Busy Light**. Enter a name, e.g. `Anna` → `sensor.teams_anna_status` /
`sensor.teams_anna_activity`, and copy the webhook URL shown after setup (also available
later under **Configure**).

## Installation

No administrator rights are needed. Download `TeamsBusyLight-Windows.zip` from the
[latest release](https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest),
unzip it and double-click `TeamsBusyLight.exe`. The program is not signed with a certificate
Windows knows, so SmartScreen may ask once: **More info** → **Run anyway**.

The installer shows the settings (see below); paste the webhook URL and click **Send test**,
then **Install**. It

* copies `TeamsBusyLight.exe` to `%LOCALAPPDATA%\Programs\TeamsBusyLight` (settings and log in
  `%LOCALAPPDATA%\TeamsBusyLight`),
* adds it to the Start menu, to "Installed apps" and to the Windows sign-in,
* starts it.

Every Windows user installs Teams Busy Light for themselves, with their own integration
entry and webhook URL.

To update, choose **Install version …** in the menu when Teams Busy Light shows a new release, or start `TeamsBusyLight.exe` of the new release; the settings are kept either way. **Check for updates...** in the menu (or **Check for updates** under General in the settings) asks right away, also when the daily check is off.

The update function installs a download only if it is signed with the project's own certificate and none of its files was changed, added or removed (the release contains the signed list `TeamsBusyLight.sha256.p7m` with the SHA-256 hashes of all files). Windows does not need to trust the certificate; the app checks it against the fingerprint it ships with. Nothing is installed without your confirmation, and the hosts file entry (administrator rights) stays with the installer.

### Update from the PowerShell versions (1.7.x and older)

Up to 1.7.x Teams Busy Light was a set of PowerShell scripts with a small starter. Security
software may report that pattern (a hidden PowerShell with `-ExecutionPolicy Bypass`, started
by a program compiled on the PC). **Install version …** in their menu updates them to the
program: the download still contains an `Install.ps1` and the signed catalog
`TeamsBusyLight.cat` that these versions check, and that script only starts the new
program. Starting `TeamsBusyLight.exe` of the download works as well. The settings, the
pause and a manually set status are kept; the scripts are removed from the program folder.

### Hosts file entry (optional)

If Home Assistant cannot be reached by its name, e.g. while a company VPN is connected,
tick **Add Home Assistant to the Windows hosts file**. The installer then resolves the
name via the DNS servers of the active LAN/Wi-Fi adapters and adds it to the hosts file
(one UAC prompt). The entry is marked so the uninstaller can remove it.

### Update from the Windows service (1.2.0 and older)

The Windows service `Microsoft Teams Status Monitor` of these versions is no longer removed by
the installer. Install version 1.7.1 first (its installer removes the service), or remove it
by hand: `sc.exe delete "Microsoft Teams Status Monitor"` as administrator, then delete
`C:\Scripts\TeamsStatus`.

### Tray icon

The Teams Busy Light icon with a colored dot (same as on macOS):

| Dot | Meaning |
|-----|---------|
| green | Available |
| red | Busy, in a meeting, presenting, focusing, do not disturb, or in a call |
| yellow | Away, be right back |
| gray | Offline (Teams not running) |
| none | Status unknown |

The icon may be hidden behind the arrow in the notification area; drag it onto the
taskbar to keep it visible. Its menu shows the status, the call state and when the status
was last sent to Home Assistant.

### Settings

Open **Settings…** in the menu of the tray icon or **Teams Busy Light** in the Start menu:

| Setting | Default | Meaning |
|---------|---------|---------|
| Home Assistant webhook URL | – | Webhook URL of the integration entry; **Send test** sends the current status |
| Keep-alive every (seconds) | 60 | Must be shorter than the offline timeout of the integration (default 180 s) |
| Check Teams every (seconds) | 2 | Check interval |
| Language of the Teams app | Detect automatically | German or English, if the detection fails |
| Send only in these networks | empty | Optional list of networks (e.g. `192.168.1.0/24, 10.0.0.0/8`); outside them nothing is sent, not even through an externally reachable webhook URL. **Add current network** fills in the network the PC is in. Empty = send everywhere |
| Ask whether to add a new network | on | While networks are set: asks whether to add a network the PC is in that is not in the list yet ("No" is remembered, "Cancel" stops asking) |
| Also detect calls in other apps | on | Reports a call while any app uses the microphone (Zoom, Webex, a browser …). Camera and microphone are sent to Home Assistant in any case, no permission needed: the microphone from the Windows audio system, the camera from the sensor activity monitor of Windows, the source of the camera privacy indicator (Windows 10 1903 and newer). This also covers virtual cameras that use a real camera, e.g. the Insta360 virtual camera: the app then shows the camera service of the vendor as the app using it. Before Windows 10 1903 the app reads the camera from the Windows privacy settings and the events of the Windows camera service |
| Start when I sign in to Windows | on | Start the app at sign-in |
| Check for updates daily | on | Shows a menu entry and a notification when a new release is available; after confirmation the app downloads, checks and installs it |
| Update channel | Release | **Beta (pre-releases)** is for testing: also offers pre-releases (`1.7.0-beta.1` …), which come before a release. Switched back to **Release** with a pre-release installed, the menu offers **Switch to release …** (the latest release, even if older) |

**Pause sending** in the menu of the tray icon stops sending for 1 hour, 8 hours, 1 day or
until **Resume sending**; Home Assistant gets `offline` once. The pause is kept when the app
restarts. The settings window shows the installed version.

**Set status** in the menu sends a status of your choice (Available, Busy, Do not disturb, Be
right back, Away) instead of the Teams status for 30 minutes, 1 or 2 hours or until **Use Teams
status again**, e.g. while you work without Teams or call from your phone. It is kept when the
app restarts; Home Assistant shows `source: manual` on the status sensor.

**Copy diagnostics** in the settings window copies version, detection, network, sending and
the last log lines (without the webhook ID) for a bug report.

## Verification

* The menu of the tray icon shows the detected status, the call state and when the status
  was last sent.
* Log with every change (**Open log** in the menu): `%LOCALAPPDATA%\TeamsBusyLight\TeamsBusyLight.log`
* Send a status manually to test the connection:
  ```powershell
  & "$env:LOCALAPPDATA\Programs\TeamsBusyLight\TeamsBusyLight.exe" --set-status busy | Out-Host
  ```

## Troubleshooting

* **Menu shows "Home Assistant: not reachable":** check the webhook URL with **Send test**
  in the settings. If the name of Home Assistant cannot be resolved (e.g. with a VPN), run
  the installer again and tick the hosts file entry.
* **Status stays unknown:** look at the `SetTaskbarIconOverlay` / `SetBadge` lines in the
  newest `MSTeams_*.log` (`%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs`).
  If your Teams language is not supported, add the wording to `app/StatusPatterns.cs` or
  [open an issue](https://github.com/SebastianInTheWild/HA-Teams-busy-light/issues/new/choose)
  with the line (remove personal data).
* **The hosts file entry was not added:** confirm the UAC prompt; run the installer again.

## Uninstall

Remove **Teams Busy Light** under Settings → Apps → Installed apps, or run
`TeamsBusyLight.exe --uninstall`. It stops and removes the app, its Start menu entry, the sign-in
entry, the settings and the log. It asks whether to remove the hosts file entries as well
(UAC prompt). The Home Assistant integration entry is not changed.

## Building

Needs the .NET SDK (any current version; the reference assemblies of .NET Framework 4.8 come
from NuGet):

```powershell
dotnet test windows/tests                                  # tests of the logic
dotnet build windows/app -c Release                        # windows/app/bin/Release/net48/TeamsBusyLight.exe
./windows/tools/build-release.ps1 -Version 2.0.0 -OutputPath dist   # the download, as in the release
```

The icon embedded in the program (`app/app-icon.ico`) holds uncompressed images, made from
`icon.ico` with `tools/New-UncompressedIcon.ps1`: compressed images look like packed data to
security software.
