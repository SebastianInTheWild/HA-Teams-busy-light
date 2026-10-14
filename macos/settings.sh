# shellcheck shell=bash disable=SC2034
# Configure the variables below that will be used in the script
HA_WEBHOOK_URL="" # Example: https://yourha.duckdns.org/api/webhook/0123456789abcdef...

# Seconds between keep-alive messages to Home Assistant. The integration marks
# Teams as offline when nothing arrives within its timeout (default 180 s).
HEARTBEAT_SECONDS=60

# Seconds between two checks
POLL_SECONDS=2
