"""Binary sensors for the Teams Busy Light integration.

Camera and microphone in use by any app on the computer (not only Teams), as
reported by the app. They stay unknown for apps that do not report them.
"""

from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorEntity
from homeassistant.const import STATE_OFF, STATE_ON
from homeassistant.core import HomeAssistant
from homeassistant.helpers.device_registry import DeviceEntryType, DeviceInfo
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.restore_state import RestoreEntity

from . import TeamsStatusConfigEntry
from .const import DOMAIN, signal_update


async def async_setup_entry(
    hass: HomeAssistant,
    entry: TeamsStatusConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Set up the camera and microphone sensors."""
    async_add_entities(
        [TeamsDeviceInUseSensor(entry, "camera"), TeamsDeviceInUseSensor(entry, "microphone")]
    )


class TeamsDeviceInUseSensor(BinarySensorEntity, RestoreEntity):
    """Camera or microphone in use.

    Entity names stay English in every UI language so their entity IDs remain
    stable (binary_sensor.teams_camera, binary_sensor.teams_microphone).
    """

    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(self, entry: TeamsStatusConfigEntry, key: str) -> None:
        """Initialize the sensor."""
        self._data = entry.runtime_data
        self._key = key
        self._attr_translation_key = key
        self._attr_unique_id = f"{entry.entry_id}_{key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name=entry.title,
            manufacturer="Microsoft",
            model="Teams",
            entry_type=DeviceEntryType.SERVICE,
        )

    @property
    def is_on(self) -> bool | None:
        """Return whether the device is in use."""
        return getattr(self._data, self._key)

    async def async_added_to_hass(self) -> None:
        """Restore the last state and listen for updates."""
        await super().async_added_to_hass()
        if getattr(self._data, self._key) is None and (
            last := await self.async_get_last_state()
        ):
            if last.state in (STATE_ON, STATE_OFF):
                setattr(self._data, self._key, last.state == STATE_ON)

        self.async_on_remove(
            async_dispatcher_connect(
                self.hass,
                signal_update(self._data.entry_id),
                self.async_write_ha_state,
            )
        )
