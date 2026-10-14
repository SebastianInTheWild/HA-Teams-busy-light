# Teams Busy Light

[![Validate](https://github.com/SebastianInTheWild/HA-Teams-busy-light/actions/workflows/validate.yml/badge.svg)](https://github.com/SebastianInTheWild/HA-Teams-busy-light/actions/workflows/validate.yml)
[![HACS Custom](https://img.shields.io/badge/HACS-Custom-41BDF5.svg)](https://hacs.xyz/docs/faq/custom_repositories/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Show your **Microsoft Teams status in Home Assistant** and turn any light into a
busy light – without Graph API, app registration or admin consent.

A small script on your Windows PC reads the status of the new Teams client and
sends it to the **Teams Busy Light** integration in Home Assistant via a webhook.

| | |
|---|---|
| **Status** | Available, Busy, In a call, In a meeting, Presenting, Focusing, Do not disturb, Be right back, Away, Offline |
| **Activity** | Not in a call, In a call, Incoming call, Outgoing call |
| **Languages** | Teams app in German or English (detected automatically), Home Assistant UI in German or English |
| **Platform** | Windows with the new Microsoft Teams (runs as a service) |

## Quick start

Click the buttons to open the matching page **in your own Home Assistant**
([My Home Assistant](https://my.home-assistant.io/) asks for your instance URL once).

### 1. Install the integration

[![Open your Home Assistant instance and open a repository inside the Home Assistant Community Store.](https://my.home-assistant.io/badges/hacs_repository.svg)](https://my.home-assistant.io/redirect/hacs_repository/?owner=SebastianInTheWild&repository=HA-Teams-busy-light&category=integration)

Download **Teams Busy Light** in HACS and restart Home Assistant.

<details>
<summary>Manual installation</summary>

Copy `custom_components/teams_status` to `<config>/custom_components/teams_status` and
restart Home Assistant.

[![Open your Home Assistant instance and show your server controls.](https://my.home-assistant.io/badges/server_controls.svg)](https://my.home-assistant.io/redirect/server_controls/)
</details>

### 2. Add the integration

[![Open your Home Assistant instance and start setting up a new integration.](https://my.home-assistant.io/badges/config_flow_start.svg)](https://my.home-assistant.io/redirect/config_flow_start/?domain=teams_status)

Keep the name `Teams` for `sensor.teams_status` / `sensor.teams_activity`, or use one
entry per person, e.g. `Teams Anna` → `sensor.teams_anna_status`.
**Copy the webhook URL** shown after setup – you need it in step 3.

Lost the URL? Open the integration and click **Configure**:

[![Open your Home Assistant instance and show an integration.](https://my.home-assistant.io/badges/integration.svg)](https://my.home-assistant.io/redirect/integration/?domain=teams_status)

### 3. Install the script on your computer

Download the [`windows`](windows) folder and run in PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\Install.ps1
```

The installer asks for the webhook URL from step 2 and installs the
`Microsoft Teams Status Monitor` service. Details: [windows/README.md](windows/README.md)

### 4. Busy light automation

[![Open your Home Assistant instance and show the blueprint import dialog with a specific blueprint pre-filled.](https://my.home-assistant.io/badges/blueprint_import.svg)](https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=https%3A%2F%2Fgithub.com%2FSebastianInTheWild%2FHA-Teams-busy-light%2Fblob%2Fmain%2Fblueprints%2Fautomation%2Fteams_status%2Fteams_busy_light.yaml)

Import the blueprint, then create an automation from it – **only the lights have to be
selected**. Colors, brightness and the Teams sensors can be changed in the collapsed sections.

[![Open your Home Assistant instance and show your blueprints.](https://my.home-assistant.io/badges/blueprints.svg)](https://my.home-assistant.io/redirect/blueprints/)

| Teams status | Light |
|--------------|-------|
| Available | green |
| Busy, In a meeting, In a call (status or activity) | red |
| Do not disturb, Presenting, Focusing | red (own color possible) |
| Away, Be right back | orange |
| Offline | off |

## Entities

| Entity | States |
|--------|--------|
| `sensor.teams_status` | `available`, `busy`, `in_a_call`, `in_a_meeting`, `presenting`, `focusing`, `do_not_disturb`, `be_right_back`, `away`, `offline` |
| `sensor.teams_activity` | `not_in_call`, `in_call`, `incoming_call`, `outgoing_call` |

The states are language-neutral, so automations work in every language; the UI shows them
translated (e.g. `in_call` → "Im Anruf" / "In a call"). The status sensor has the attributes
`computer`, `teams_language` and `last_seen`.

If a computer stops reporting (shut down, asleep), the integration sets the status to
`offline` after the timeout (default 180 s, change it under **Configure**).

## How it works

```
Teams log / call state ──► script (Windows service)
                              │  POST {"status": "busy", "activity": "in_call", ...}
                              ▼
               Home Assistant webhook ──► sensor.teams_status / sensor.teams_activity
                                                     │
                                                     ▼
                                       Busy light automation (blueprint)
```

The script reads the status from the Teams log (`SetTaskbarIconOverlay` / `SetBadge`) in the
language of the Teams app and the call state from call events in the same log.

No long-lived access token is needed; the webhook ID is the secret – treat the URL like a password.

## Add a language

The status is written to the Teams log in the language of the Teams app. Add the wording of
your language to [`windows/Languages.ps1`](windows/Languages.ps1) and open a pull request.

## Troubleshooting

* **Status not recognized:** look for lines with `SetTaskbarIconOverlay` / `SetBadge` in the
  newest `MSTeams_*.log` and [open an issue](https://github.com/SebastianInTheWild/HA-Teams-busy-light/issues/new/choose)
  with the line (remove personal data).
* **Entities are named `…_2`:** an older entity with the same ID exists – remove it under
  Settings → Entities and rename the new one.

[![Open your Home Assistant instance and show your entities.](https://my.home-assistant.io/badges/entities.svg)](https://my.home-assistant.io/redirect/entities/)

## Credits

Based on [TeamsStatus](https://github.com/EBOOZ/TeamsStatus) by Danny de Vries (MIT).

Not affiliated with or endorsed by Microsoft. Microsoft Teams is a trademark of Microsoft Corporation.

## License

[MIT](LICENSE)
