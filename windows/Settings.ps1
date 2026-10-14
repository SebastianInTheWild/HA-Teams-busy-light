# Add one entry for every Windows user. Each user needs a separate Home Assistant
# integration entry and webhook URL.
$TeamsUsers = @(
    @{
        Username = ""
        HAWebhookUrl = ""
    }
)

# UI language selected by the installer. Add a matching file under Translations
# to support another language. Teams status-log language detection is separate.
$UiLanguage = "en"

# Language of the Teams app as it appears in the logfile.
# "auto" detects it from the log (see Languages.ps1), or force one: "de", "en"
$TeamsLanguage = "auto"

# Seconds between keep-alive messages to Home Assistant. The integration marks
# Teams as offline when nothing arrives within its timeout (default 180 s).
$HeartbeatSeconds = 60
