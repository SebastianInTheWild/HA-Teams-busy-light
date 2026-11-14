"""Fixtures for the Teams Busy Light tests."""

import pytest


@pytest.fixture(autouse=True)
def auto_enable_custom_integrations(enable_custom_integrations):
    """Load custom_components/teams_status in every test."""
    return
