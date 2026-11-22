"""Tests for the webhook, sensors and repair issue of Teams Busy Light."""

from __future__ import annotations

from datetime import timedelta

import pytest
from pytest_homeassistant_custom_component.common import (
    MockConfigEntry,
    async_capture_events,
    async_fire_time_changed,
)

from homeassistant.const import CONF_WEBHOOK_ID
from homeassistant.core import HomeAssistant
from homeassistant.helpers import device_registry as dr, issue_registry as ir
from homeassistant.setup import async_setup_component
from homeassistant.util import dt as dt_util

from custom_components.teams_status.const import (
    DOMAIN,
    EVENT_STATUS_CHANGED,
    issue_id_outdated_app,
)

WEBHOOK_ID = "test_webhook"


@pytest.fixture
async def entry(hass: HomeAssistant) -> MockConfigEntry:
    """Set up one config entry with a webhook."""
    await async_setup_component(hass, "http", {})
    entry = MockConfigEntry(domain=DOMAIN, title="Teams", data={CONF_WEBHOOK_ID: WEBHOOK_ID})
    entry.add_to_hass(hass)
    assert await hass.config_entries.async_setup(entry.entry_id)
    await hass.async_block_till_done()
    return entry


async def _post(hass_client_no_auth, payload: dict) -> int:
    client = await hass_client_no_auth()
    response = await client.post(f"/api/webhook/{WEBHOOK_ID}", json=payload)
    return response.status


async def _integration_version(hass: HomeAssistant) -> str:
    from homeassistant.loader import async_get_integration

    return str((await async_get_integration(hass, DOMAIN)).version)


async def test_old_app_message(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """Messages of apps up to 1.4.0 keep working; new sensors stay unknown."""
    assert await _post(hass_client_no_auth, {"status": "busy", "activity": "in_call", "computer": "PC"}) == 200
    await hass.async_block_till_done()
    status = hass.states.get("sensor.teams_status")
    assert status.state == "busy"
    assert status.attributes["source"] == "teams"
    assert status.attributes["app_version"] is None
    assert hass.states.get("sensor.teams_activity").state == "in_call"
    assert hass.states.get("binary_sensor.teams_camera").state == "unknown"
    assert hass.states.get("binary_sensor.teams_microphone").state == "unknown"
    assert not ir.async_get(hass).async_get_issue(DOMAIN, issue_id_outdated_app(entry.entry_id))


async def test_new_fields(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """Camera, microphone, source, version and platform are applied."""
    version = await _integration_version(hass)
    payload = {
        "status": "do_not_disturb",
        "source": "manual",
        "activity": "not_in_call",
        "camera": True,
        "microphone": False,
        "app_version": version,
        "platform": "macos",
        "computer": "Mac",
        "unknown_field": 1,
    }
    assert await _post(hass_client_no_auth, payload) == 200
    await hass.async_block_till_done()
    status = hass.states.get("sensor.teams_status")
    assert status.state == "do_not_disturb"
    assert status.attributes["source"] == "manual"
    assert status.attributes["platform"] == "macos"
    assert hass.states.get("binary_sensor.teams_camera").state == "on"
    assert hass.states.get("binary_sensor.teams_microphone").state == "off"
    devices = dr.async_entries_for_config_entry(dr.async_get(hass), entry.entry_id)
    assert [device.sw_version for device in devices] == [version]
    assert not ir.async_get(hass).async_get_issue(DOMAIN, issue_id_outdated_app(entry.entry_id))

    # A message without status (e.g. only camera) keeps the source
    assert await _post(hass_client_no_auth, {"camera": False}) == 200
    await hass.async_block_till_done()
    assert hass.states.get("sensor.teams_status").attributes["source"] == "manual"
    assert hass.states.get("binary_sensor.teams_camera").state == "off"


async def test_invalid_values(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """Wrong types are rejected."""
    assert await _post(hass_client_no_auth, {"camera": "yes"}) == 400
    assert await _post(hass_client_no_auth, {"source": "graph"}) == 400
    assert await _post(hass_client_no_auth, {"platform": "linux"}) == 400


async def test_outdated_app_issue(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """An older app raises a repair issue, the update removes it."""
    issues = ir.async_get(hass)
    issue_id = issue_id_outdated_app(entry.entry_id)

    assert await _post(hass_client_no_auth, {"status": "available", "app_version": "1.0.0", "computer": "PC"}) == 200
    await hass.async_block_till_done()
    issue = issues.async_get_issue(DOMAIN, issue_id)
    assert issue is not None
    assert issue.translation_placeholders["computer"] == "PC"
    assert issue.translation_placeholders["app_version"] == "1.0.0"

    assert await _post(hass_client_no_auth, {"status": "available", "app_version": await _integration_version(hass)}) == 200
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is None

    # The app of a pre-release (1.7.0-beta.3 with integration 1.7.0) is not older
    beta = f"{await _integration_version(hass)}-beta.3"
    assert await _post(hass_client_no_auth, {"app_version": beta}) == 200
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is None

    # Nonsense versions never raise the issue
    assert await _post(hass_client_no_auth, {"app_version": "dev-build"}) == 200
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is None

    # Builds without a version neither
    assert await _post(hass_client_no_auth, {"app_version": "0.0.0"}) == 200
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is None

    # Removing the entry removes the issue
    assert await _post(hass_client_no_auth, {"app_version": "0.9.0"}) == 200
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is not None
    assert await hass.config_entries.async_remove(entry.entry_id)
    await hass.async_block_till_done()
    assert issues.async_get_issue(DOMAIN, issue_id) is None


async def test_timeout(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """Without messages Teams goes offline and camera/microphone off."""
    assert await _post(hass_client_no_auth, {"status": "busy", "camera": True, "microphone": True}) == 200
    await hass.async_block_till_done()
    async_fire_time_changed(hass, dt_util.utcnow() + timedelta(seconds=181))
    await hass.async_block_till_done()
    assert hass.states.get("sensor.teams_status").state == "offline"
    assert hass.states.get("binary_sensor.teams_camera").state == "off"
    assert hass.states.get("binary_sensor.teams_microphone").state == "off"


async def test_status_changed_event(hass: HomeAssistant, entry, hass_client_no_auth) -> None:
    """Status and activity changes fire an event with the device ID, others do not."""
    events = async_capture_events(hass, EVENT_STATUS_CHANGED)
    (device,) = dr.async_entries_for_config_entry(dr.async_get(hass), entry.entry_id)

    assert await _post(hass_client_no_auth, {"status": "busy", "activity": "in_call"}) == 200
    assert await _post(hass_client_no_auth, {"status": "busy", "camera": True}) == 200
    assert await _post(hass_client_no_auth, {"activity": "not_in_call"}) == 200
    await hass.async_block_till_done()
    assert [e.data for e in events] == [
        {
            "device_id": device.id,
            "entry_id": entry.entry_id,
            "status": "busy",
            "activity": "in_call",
            "source": "teams",
        },
        {
            "device_id": device.id,
            "entry_id": entry.entry_id,
            "status": "busy",
            "activity": "not_in_call",
            "source": "teams",
        },
    ]

    async_fire_time_changed(hass, dt_util.utcnow() + timedelta(seconds=181))
    await hass.async_block_till_done()
    assert events[-1].data["status"] == "offline"
    assert len(events) == 3
