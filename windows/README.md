# Teams Status Monitor for Home Assistant

> [!NOTE]
> This solution only works for the new version of Microsoft Teams. You may want to consider [Get-MonitorStatus](https://github.com/EBOOZ/Get-MonitorStatus) in combination with this script as well.

## Introduction

We're working a lot at our home office these days. Several people already found solutions to make working in the home office more comfortable. One of these ways is to automate activities in your home automatation system based on your status on Microsoft Teams.

Microsoft provides the status of your account that is used in Teams via the Graph API. To access the Graph API, your organization needs to grant consent for the organization so everybody can read their Teams status. Since my organization didn't want to grant consent, I needed to find a workaround, which I found in monitoring the Teams client logfile for certain changes.

The script sends the status to the **Teams Busy Light** custom integration
(`custom_components/teams_status`) in Home Assistant via a webhook. The integration
provides two sensors:

* `sensor.teams_status` – availability (`available`, `busy`, `in_a_call`, `in_a_meeting`, `presenting`, `focusing`, `do_not_disturb`, `be_right_back`, `away`, `offline`)
* `sensor.teams_activity` – call activity (`not_in_call`, `in_call`, `incoming_call`, `outgoing_call`)

The states are language-neutral; Home Assistant shows them translated (German/English).

Every user/computer adds its own integration entry and gets its own webhook and sensors.

### Language of the Teams app

The new Teams client writes the status into its logfile in the language of the app.
`Languages.ps1` contains the patterns per language (currently German and English).
With `$TeamsLanguage = "auto"` (default, `Settings.ps1`) the language is detected
from the log line itself; set `"de"` or `"en"` to force one.

### Offline detection

The script sends a keep-alive every `$HeartbeatSeconds` (60 s). If Home Assistant
receives nothing within the timeout of the integration (180 s, see integration
options), Teams is set to `offline` – e.g. when the computer is shut down.

## Requirements

* Windows client with the new Microsoft Teams installed
* Home Assistant reachable from the client
* `nssm.exe`, `Get-TeamsStatus.ps1`, `Languages.ps1`, `Settings.ps1`, and `Install.ps1` in the same folder

## Home Assistant integration

1. Copy `custom_components/teams_status` to `<config>/custom_components/teams_status`
2. Restart Home Assistant
3. Settings → Devices & Services → Add Integration → **Teams Busy Light**
4. Keep the name `Teams` (entities become `sensor.teams_status` / `sensor.teams_activity`)
5. Copy the webhook URL shown after setup (also visible later under *Configure*)

No long-lived access token is needed anymore.

## Installation (recommended)

Run `Install.ps1` from the script folder:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\Install.ps1
```

The installer opens a window where you enter:

* Home Assistant webhook URL (`https://.../api/webhook/...`)
* Local Windows username (pre-filled from the signed-in user and editable)

What `Install.ps1` does:

* Automatically elevates to Administrator if required
* Pre-fills the signed-in username (with fallbacks)
* Writes values into `C:\Scripts\TeamsStatus\Settings.ps1`
* Resolves the Home Assistant DNS name from the webhook URL using DNS servers from active LAN/Wi-Fi adapters
* Adds or updates the resolved mapping in the Windows hosts file (`%windir%\System32\drivers\etc\hosts`)
* Copies script files to `C:\Scripts\TeamsStatus`
* Installs (or, when already installed, restarts) the `Microsoft Teams Status Monitor` service via NSSM

## Busy light blueprint

`blueprints/automation/teams_status/teams_busy_light.yaml` switches lights according
to the Teams status – only the lights have to be selected. Colors, brightness and
the sensors can be changed in the collapsed sections.

## Verification

After installation:

* Start Microsoft Teams
* Check if `sensor.teams_status` and `sensor.teams_activity` update in Home Assistant
* Set a status manually: `.\Get-TeamsStatus.ps1 -SetStatus busy`
* Verify service status:

```powershell
Get-Service -Name "Microsoft Teams Status Monitor"
```

## Troubleshooting

* If hosts update fails, confirm the UAC elevation prompt was accepted
* If DNS resolution fails, verify network adapter DNS settings and HA DNS record
* If the status is not recognized, look at the `SetTaskbarIconOverlay` / `SetBadge` lines in the Teams log and add the wording to `Languages.ps1`
* If username auto-detection picks the wrong user on shared systems, rerun `Install.ps1` and edit the username in the installer window
