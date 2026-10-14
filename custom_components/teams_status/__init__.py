"""The Teams Busy Light integration.

Receives the Teams status from the Windows script (windows/Get-TeamsStatus.ps1)
via a webhook and provides it as sensors.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime
from http import HTTPStatus
import logging
from typing import Any

from aiohttp import web
import voluptuous as vol

from homeassistant.components import webhook
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_WEBHOOK_ID, Platform
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.event import async_call_later
from homeassistant.util import dt as dt_util

from .const import (
    ACTIVITY_NOT_IN_CALL,
    ACTIVITY_OPTIONS,
    CONF_TIMEOUT,
    DEFAULT_TIMEOUT,
    DOMAIN,
    STATUS_OFFLINE,
    STATUS_OPTIONS,
    signal_update,
)

_LOGGER = logging.getLogger(__name__)

PLATFORMS = [Platform.SENSOR]

WEBHOOK_SCHEMA = vol.Schema(
    {
        vol.Optional("status"): vol.All(str, vol.Lower, vol.In(STATUS_OPTIONS)),
        vol.Optional("activity"): vol.All(str, vol.Lower, vol.In(ACTIVITY_OPTIONS)),
        vol.Optional("language"): str,
        vol.Optional("computer"): str,
    },
    extra=vol.REMOVE_EXTRA,
)


class TeamsStatusData:
    """Current Teams status of one config entry."""

    def __init__(self, hass: HomeAssistant, entry_id: str, timeout: int) -> None:
        """Initialize the data."""
        self.hass = hass
        self.entry_id = entry_id
        self.timeout = timeout
        self.status: str | None = None
        self.activity: str | None = None
        self.language: str | None = None
        self.computer: str | None = None
        self.last_seen: datetime | None = None
        self._cancel_timeout: Callable[[], None] | None = None

    @callback
    def async_update(self, data: dict[str, Any]) -> None:
        """Apply a message from the script."""
        for key in ("status", "activity", "language", "computer"):
            if key in data:
                setattr(self, key, data[key])
        self.last_seen = dt_util.utcnow()
        self.async_schedule_timeout()
        async_dispatcher_send(self.hass, signal_update(self.entry_id))

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
        async_dispatcher_send(self.hass, signal_update(self.entry_id))

    @callback
    def async_shutdown(self) -> None:
        """Cancel the timeout timer."""
        if self._cancel_timeout is not None:
            self._cancel_timeout()
            self._cancel_timeout = None


type TeamsStatusConfigEntry = ConfigEntry[TeamsStatusData]


async def async_setup_entry(hass: HomeAssistant, entry: TeamsStatusConfigEntry) -> bool:
    """Set up Teams Busy Light from a config entry."""
    data = TeamsStatusData(
        hass, entry.entry_id, int(entry.options.get(CONF_TIMEOUT, DEFAULT_TIMEOUT))
    )
    entry.runtime_data = data

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)

    async def handle_webhook(
        hass: HomeAssistant, webhook_id: str, request: web.Request
    ) -> web.Response:
        """Handle a status message from the Windows script."""
        try:
            payload = WEBHOOK_SCHEMA(await request.json())
        except (ValueError, vol.Invalid) as err:
            _LOGGER.warning("Invalid message from Teams status script: %s", err)
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


async def async_unload_entry(hass: HomeAssistant, entry: TeamsStatusConfigEntry) -> bool:
    """Unload a config entry."""
    webhook.async_unregister(hass, entry.data[CONF_WEBHOOK_ID])
    entry.runtime_data.async_shutdown()
    return await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
