"""The Teams Busy Light integration.

Receives the Teams status from the Teams Busy Light app on Windows (tray app)
or macOS (menu bar app) via a webhook and provides it as sensors. Newer apps
also report whether the camera or microphone is in use (by any app) and their
own version; an app older than the integration raises a repair issue.
Changes of the status or the call activity are also fired as the event
teams_status_changed with the device ID, so the blueprint needs only the device.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from http import HTTPStatus
import logging
from typing import Any

from aiohttp import web
from awesomeversion import AwesomeVersion
import voluptuous as vol

from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_WEBHOOK_ID, Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import device_registry as dr, issue_registry as ir
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import async_call_later
from homeassistant.loader import async_get_integration
from homeassistant.util import dt as dt_util

from .const import (
    ACTIVITY_NOT_IN_CALL,
    ACTIVITY_OPTIONS,
    CONF_TIMEOUT,
    DEFAULT_TIMEOUT,
    DOMAIN,
    EVENT_STATUS_CHANGED,
    PLATFORM_OPTIONS,
    SOURCE_OPTIONS,
    SOURCE_TEAMS,
    STATUS_OFFLINE,
    STATUS_OPTIONS,
    issue_id_outdated_app,
    signal_update,
)

_LOGGER = logging.getLogger(__name__)

PLATFORMS = [Platform.BINARY_SENSOR, Platform.SENSOR]

WEBHOOK_SCHEMA = vol.Schema(
    {
        vol.Optional("status"): vol.All(str, vol.Lower, vol.In(STATUS_OPTIONS)),
        vol.Optional("activity"): vol.All(str, vol.Lower, vol.In(ACTIVITY_OPTIONS)),
        vol.Optional("language"): str,
        vol.Optional("computer"): str,
        vol.Optional("source"): vol.All(str, vol.Lower, vol.In(SOURCE_OPTIONS)),
        vol.Optional("camera"): bool,
        vol.Optional("microphone"): bool,
        vol.Optional("app_version"): vol.All(str, vol.Length(max=32)),
        vol.Optional("platform"): vol.All(str, vol.Lower, vol.In(PLATFORM_OPTIONS)),
    },
    extra=vol.REMOVE_EXTRA,
)


class TeamsStatusData:
    """Current Teams status of one config entry."""

    def __init__(
        self,
        hass: HomeAssistant,
        entry_id: str,
        timeout: int,
        integration_version: str | None,
    ) -> None:
        """Initialize the data."""
        self.hass = hass
        self.entry_id = entry_id
        self.timeout = timeout
        self.integration_version = integration_version
        self.status: str | None = None
        self.activity: str | None = None
        self.language: str | None = None
        self.computer: str | None = None
        self.source: str | None = None
        self.camera: bool | None = None
        self.microphone: bool | None = None
        self.app_version: str | None = None
        self.platform: str | None = None
        self.last_seen: datetime | None = None
        self._cancel_timeout: Callable[[], None] | None = None
        self._fired: tuple[str | None, str | None] | None = None

    @callback
    def async_update(self, data: dict[str, Any]) -> None:
        """Apply a message from the app."""
        for key in (
            "status",
            "activity",
            "language",
            "computer",
            "camera",
            "microphone",
            "platform",
        ):
            if key in data:
                setattr(self, key, data[key])
        if "status" in data:
            # Older apps do not send the source; their status always comes from Teams
            self.source = data.get("source", SOURCE_TEAMS)
        if "app_version" in data and data["app_version"] != self.app_version:
            self.app_version = data["app_version"]
            self._async_app_version_changed()
        self.last_seen = dt_util.utcnow()
        self.async_schedule_timeout()
        self._async_notify()

    @callback
    def _async_notify(self) -> None:
        """Update the entities and fire an event when status or activity changed.

        The first message after a restart always fires, so automations resync.
        """
        async_dispatcher_send(self.hass, signal_update(self.entry_id))
        current = (self.status, self.activity)
        if current == self._fired:
            return
        self._fired = current
        # The entry has exactly one device (identifier (DOMAIN, entry_id))
        devices = dr.async_entries_for_config_entry(
            dr.async_get(self.hass), self.entry_id
        )
        self.hass.bus.async_fire(
            EVENT_STATUS_CHANGED,
            {
                "device_id": devices[0].id if devices else None,
                "entry_id": self.entry_id,
                "status": self.status,
                "activity": self.activity,
                "source": self.source,
            },
        )

    @callback
    def _async_app_version_changed(self) -> None:
        """Show the app version on the device and check whether it is outdated."""
        registry = dr.async_get(self.hass)
        for device in dr.async_entries_for_config_entry(registry, self.entry_id):
            registry.async_update_device(device.id, sw_version=self.app_version)

        issue_id = issue_id_outdated_app(self.entry_id)
        if self.app_version and self.integration_version and _is_older(
            self.app_version, self.integration_version
        ):
            ir.async_create_issue(
                self.hass,
                DOMAIN,
                issue_id,
                is_fixable=False,
                severity=ir.IssueSeverity.WARNING,
                translation_key="outdated_app",
                translation_placeholders={
                    "computer": self.computer or "?",
                    "app_version": self.app_version,
                    "integration_version": self.integration_version,
                },
                learn_more_url="https://github.com/SebastianInTheWild/HA-Teams-busy-light/releases/latest",
            )
        else:
            ir.async_delete_issue(self.hass, DOMAIN, issue_id)

    @callback
    def async_schedule_timeout(self) -> None:
        """(Re)start the timer that sets Teams offline when the script is silent."""
        self.async_shutdown()
        if self.timeout > 0:
            self._cancel_timeout = async_call_later(
                self.hass, self.timeout, self._async_timed_out
            )

    @callback
    def _async_timed_out(self, _now: datetime) -> None:
        """Handle a missing keep-alive, e.g. because the computer is off."""
        self._cancel_timeout = None
        _LOGGER.debug("No message for %s seconds, setting Teams offline", self.timeout)
        self.status = STATUS_OFFLINE
        self.activity = ACTIVITY_NOT_IN_CALL
        if self.camera is not None:
            self.camera = False
        if self.microphone is not None:
            self.microphone = False
        self._async_notify()

    @callback
    def async_shutdown(self) -> None:
        """Cancel the timeout timer."""
        if self._cancel_timeout is not None:
            self._cancel_timeout()
            self._cancel_timeout = None


def _is_older(version: str, than: str) -> bool:
    """Compare two versions; unparsable versions are never reported as older.

    0.0.0 is a build without a version (e.g. run from a clone of the repository).
    """
    if version == "0.0.0":
        return False
    try:
        return AwesomeVersion(version) < AwesomeVersion(than)
    except Exception:  # noqa: BLE001 - any odd version string from the app
        return False


type TeamsStatusConfigEntry = ConfigEntry[TeamsStatusData]


async def async_setup_entry(hass: HomeAssistant, entry: TeamsStatusConfigEntry) -> bool:
    """Set up Teams Busy Light from a config entry."""
    integration = await async_get_integration(hass, DOMAIN)
    data = TeamsStatusData(
        hass,
        entry.entry_id,
        int(entry.options.get(CONF_TIMEOUT, DEFAULT_TIMEOUT)),
        str(integration.version) if integration.version else None,
    )
    entry.runtime_data = data

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    async def handle_webhook(
        hass: HomeAssistant, webhook_id: str, request: web.Request
    ) -> web.Response:
        """Handle a status message from the app."""
        try:
            payload = WEBHOOK_SCHEMA(await request.json())
        except (ValueError, vol.Invalid) as err:
            _LOGGER.warning("Invalid message from Teams Busy Light: %s", err)
            return web.Response(status=HTTPStatus.BAD_REQUEST, text=str(err))
        data.async_update(payload)
        return web.Response(status=HTTPStatus.OK)

    webhook.async_register(
        hass,
        DOMAIN,
        entry.title,
        entry.data[CONF_WEBHOOK_ID],
        handle_webhook,
        local_only=False,
        allowed_methods=["POST"],
    )

    # Restored states go offline if the computer does not report after a restart
    data.async_schedule_timeout()

    entry.async_on_unload(entry.add_update_listener(_async_update_listener))
    return True


async def _async_update_listener(
    hass: HomeAssistant, entry: TeamsStatusConfigEntry
) -> None:
    """Reload the entry when the options change."""
    await hass.config_entries.async_reload(entry.entry_id)


async def async_remove_entry(hass: HomeAssistant, entry: TeamsStatusConfigEntry) -> None:
    """Remove the repair issue of a deleted entry."""
    ir.async_delete_issue(hass, DOMAIN, issue_id_outdated_app(entry.entry_id))


async def async_unload_entry(hass: HomeAssistant, entry: TeamsStatusConfigEntry) -> bool:
    """Unload a config entry."""
    webhook.async_unregister(hass, entry.data[CONF_WEBHOOK_ID])
    entry.runtime_data.async_shutdown()
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
