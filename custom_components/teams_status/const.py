"""Constants for the Teams Busy Light integration."""

DOMAIN = "teams_status"

CONF_TIMEOUT = "timeout"
DEFAULT_NAME = "Teams"
DEFAULT_TIMEOUT = 180  # seconds without a message until Teams is offline, 0 = never

STATUS_OFFLINE = "offline"
STATUS_OPTIONS = [
    "available",
    "busy",
    "in_a_call",
    "in_a_meeting",
    "presenting",
    "focusing",
    "do_not_disturb",
    "be_right_back",
    "away",
    STATUS_OFFLINE,
]

ACTIVITY_NOT_IN_CALL = "not_in_call"
ACTIVITY_OPTIONS = [
    ACTIVITY_NOT_IN_CALL,
    "in_call",
    "incoming_call",
    "outgoing_call",
]


def signal_update(entry_id: str) -> str:
    """Return the dispatcher signal for updates of a config entry."""
    return f"{DOMAIN}_update_{entry_id}"
