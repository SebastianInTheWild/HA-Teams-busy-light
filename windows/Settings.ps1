# Configure the variables below that will be used in the script
$HAWebhookUrl = "" # Example: https://yourha.duckdns.org/api/webhook/0123456789abcdef...
$LocalUsername = "" # Example: your.username

# Language of the Teams app as it appears in the logfile.
# "auto" detects it from the log (see Languages.ps1), or force one: "de", "en"
$TeamsLanguage = "auto"

# Seconds between keep-alive messages to Home Assistant. The integration marks
# Teams as offline when nothing arrives within its timeout (default 180 s).
$HeartbeatSeconds = 60
