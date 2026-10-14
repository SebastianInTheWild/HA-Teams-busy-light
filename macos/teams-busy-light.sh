#!/bin/bash
#
# Sends the status of Microsoft Teams on macOS to the "Teams Busy Light"
# custom integration in Home Assistant via its webhook.
#
# - Status: read from the Teams logfile. The Mac client logs the presence
#   with language-neutral English values (e.g. "Busy"), regardless of the
#   language of the Teams app.
# - Activity: a running Teams call is detected by the power assertion
#   "Microsoft Teams Call in progress" (pmset -g assertions).
#
# Usage:
#   teams-busy-light.sh                      monitor Teams (run by launchd)
#   teams-busy-light.sh --set-status busy    send a status once and exit
#   teams-busy-light.sh --show               print the detected state once
#
# Compatible with the bash 3.2 that ships with macOS.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=settings.sh
. "$SCRIPT_DIR/settings.sh"

export LC_ALL=en_US.UTF-8

: "${HEARTBEAT_SECONDS:=60}"
: "${POLL_SECONDS:=2}"

LOG_DIR="$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams/Library/Application Support/Logs"
# Log lines with the own presence, e.g.
#   AppMenuMac: UpdateIconPresenceSending presence update to icon v2: Busy
#   tmpcore::TmpcoreService: OnAvailabilityUpdate Received availability update: Busy cloud type: ...
# Values can contain spaces ("Do Not Disturb"); they are removed before mapping.
PRESENCE_PATTERN='(presence update to icon v2|Received availability update): .*'
CALL_ASSERTION='Microsoft Teams Call in progress'

COMPUTER="$(scutil --get ComputerName 2>/dev/null || hostname)"

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Sends status and activity to the Home Assistant webhook
send_status() {
    local body
    body="{\"computer\":\"$(json_escape "$COMPUTER")\""
    [ -n "$1" ] && body="$body,\"status\":\"$1\""
    [ -n "$2" ] && body="$body,\"activity\":\"$2\""
    body="$body}"

    if ! curl -fsS -m 10 -X POST -H "Content-Type: application/json" \
        --data "$body" "$HA_WEBHOOK_URL" >/dev/null; then
        echo "$(date '+%F %T') Failed to send status to Home Assistant." >&2
        return 1
    fi
}

teams_running() {
    pgrep -x MSTeams >/dev/null 2>&1
}

teams_in_call() {
    pmset -g assertions 2>/dev/null | grep -q "$CALL_ASSERTION"
}

# Maps a Teams presence value to the state of the integration. Teams does not
# use consistent casing ("Do Not Disturb", "Do not disturb"), so the value is
# compared in lower case without spaces.
map_presence() {
    case "$(printf '%s' "$1" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" in
        available | availableidle) echo available ;;
        busy | busyidle) echo busy ;;
        inacall | onthephone) echo in_a_call ;;
        inameeting | inaconferencecall) echo in_a_meeting ;;
        presenting) echo presenting ;;
        focusing) echo focusing ;;
        donotdisturb) echo do_not_disturb ;;
        berightback) echo be_right_back ;;
        away | awayidle) echo away ;;
        offline | invisible | appearoffline) echo offline ;;
        *) return 1 ;;
    esac
}

# Prints the last presence value of a logfile without spaces (e.g. "DoNotDisturb")
presence_in_file() {
    grep -Eo "$PRESENCE_PATTERN" "$1" 2>/dev/null | tail -n 1 |
        sed -E 's/^[^:]*: //; s/ cloud type:.*//' | tr -d ' 
	'
}

# Prints the last known presence, searching older logfiles if the newest
# one (e.g. right after a log rotation) has no presence yet
latest_presence() {
    local file value
    # Teams names the logs itself (MSTeams_<date>.log), so ls -t is safe here
    # shellcheck disable=SC2012
    ls -t "$LOG_DIR"/MSTeams_*.log 2>/dev/null | while IFS= read -r file; do
        value="$(presence_in_file "$file")"
        if [ -n "$value" ]; then
            echo "$value"
            break
        fi
    done
}

if [ "$1" = "--show" ]; then
    presence="$(latest_presence)"
    echo "Teams running: $(teams_running && echo yes || echo no)"
    echo "Presence:      ${presence:-unknown} -> $(map_presence "$presence" || echo "not mapped")"
    echo "In a call:     $(teams_in_call && echo yes || echo no)"
    exit 0
fi

if [ -z "$HA_WEBHOOK_URL" ]; then
    echo "HA_WEBHOOK_URL is not set in settings.sh." >&2
    exit 1
fi

# Send a status once when called with --set-status
if [ "$1" = "--set-status" ]; then
    echo "Setting Microsoft Teams status to $2:"
    send_status "$2" "$3" && echo "Status set successfully."
    exit $?
fi

echo "$(date '+%F %T') Teams Busy Light started on $COMPUTER"
# macOS protects the data of other apps; without access the status stays unknown
if ! ls "$LOG_DIR" >/dev/null 2>&1; then
    echo "$(date '+%F %T') Cannot read the Teams logs in: $LOG_DIR" >&2
    echo "$(date '+%F %T') Allow \"Teams Busy Light\" access to data from other apps, or add it under" >&2
    echo "$(date '+%F %T') System Settings > Privacy & Security > Full Disk Access (~/Applications)." >&2
fi

status=""
activity=""
sent_status=""
sent_activity=""
last_sent=0
retry_after=0
unknown_logged=""

# Start monitoring Teams
while true; do
    now=$(date +%s)

    if teams_running; then
        presence="$(latest_presence)"
        if mapped="$(map_presence "$presence")"; then
            status="$mapped"
        elif [ -n "$presence" ] && [ "$presence" != "$unknown_logged" ]; then
            # Keep the previous status, but report the value so it can be added
            echo "$(date '+%F %T') Unknown Teams presence: $presence" >&2
            unknown_logged="$presence"
        fi

        if teams_in_call; then
            activity="in_call"
        else
            activity="not_in_call"
        fi
    # Set status to offline when Teams is not running
    else
        status="offline"
        activity="not_in_call"
    fi

    # Send on every change and as keep-alive every HEARTBEAT_SECONDS
    changed=0
    if [ "$status" != "$sent_status" ] || [ "$activity" != "$sent_activity" ]; then
        changed=1
    fi
    if { [ $changed -eq 1 ] || [ $((now - last_sent)) -ge "$HEARTBEAT_SECONDS" ]; } && [ "$now" -ge "$retry_after" ]; then
        [ $changed -eq 1 ] && echo "$(date '+%F %T') Status: ${status:-none}, activity: $activity"
        if send_status "$status" "$activity"; then
            sent_status="$status"
            sent_activity="$activity"
            last_sent=$now
        else
            retry_after=$((now + 10))
        fi
    fi

    sleep "$POLL_SECONDS"
done
