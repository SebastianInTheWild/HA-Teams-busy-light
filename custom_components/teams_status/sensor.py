"""Sensors for the Teams Busy Light integration."""

from __future__ import annotations

from typing import Any

from homeassistant.components.sensor import RestoreSensor, SensorDeviceClass
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from . import TeamsStatusConfigEntry
from .const import ACTIVITY_OPTIONS, DOMAIN, STATUS_OPTIONS, signal_update


async def async_setup_entry(
    hass: HomeAssistant,
    entry: TeamsStatusConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the Teams sensors."""
    async_add_entities(
        [
            TeamsStatusSensor(entry, "status", STATUS_OPTIONS),
            TeamsStatusSensor(entry, "activity", ACTIVITY_OPTIONS),
        ]
    )


class TeamsStatusSensor(RestoreSensor):
    """Teams availability status or call activity.

    Entity names stay English in every UI language so their entity IDs remain
    stable (for example, sensor.teams_status and sensor.teams_activity).
    """

    _attr_has_entity_name = True
    _attr_should_poll = False
    _attr_device_class = SensorDeviceClass.ENUM

    def __init__(
        self, entry: TeamsStatusConfigEntry, key: str, options: list[str]
    ) -> None:
        """Initialize the sensor."""
        self._data = entry.runtime_data
        self._key = key
        self._attr_translation_key = key
        self._attr_options = options
        self._attr_unique_id = f"{entry.entry_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
            manufacturer="Microsoft",
            model="Teams",
            entry_type=DeviceEntryType.SERVICE,
        )

    @property
    def native_value(self) -> str | None:
        """Return the current state."""
        return getattr(self._data, self._key)

    @property
    def extra_state_attributes(self) -> dict[str, Any] | None:
        """Return details about the reporting computer on the status sensor."""
        if self._key != "status":
            return None
        return {
            "computer": self._data.computer,
            "teams_language": self._data.language,
            "last_seen": self._data.last_seen.isoformat()
            if self._data.last_seen
            else None,
        }

    async def async_added_to_hass(self) -> None:
        """Restore the last state and listen for updates."""
        await super().async_added_to_hass()
        if getattr(self._data, self._key) is None and (
            last := await self.async_get_last_sensor_data()
        ):
            if last.native_value in self.options:
                setattr(self._data, self._key, last.native_value)

        self.async_on_remove(
            async_dispatcher_connect(
                self.hass,
                signal_update(self._data.entry_id),
                self.async_write_ha_state,
            )
        )
