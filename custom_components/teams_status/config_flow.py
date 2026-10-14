<<<<<<< HEAD
"""Config flow for the Teams Busy Light integration."""

from __future__ import annotations

from typing import Any

import voluptuous as vol

from homeassistant.components import webhook
from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
)
from homeassistant.const import CONF_NAME, CONF_WEBHOOK_ID
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.network import NoURLAvailableError
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
)

from .const import CONF_TIMEOUT, DEFAULT_NAME, DEFAULT_TIMEOUT, DOMAIN


def _webhook_url(hass: HomeAssistant, webhook_id: str) -> str:
    """Return the URL the Windows script has to post to."""
    try:
        return webhook.async_generate_url(hass, webhook_id)
    except NoURLAvailableError:
        return f"https://<your-home-assistant>{webhook.async_generate_path(webhook_id)}"


class TeamsStatusConfigFlow(ConfigFlow, domain=DOMAIN):
    """Create a webhook that receives the Teams status."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Handle the initial step."""
        if user_input is not None:
            webhook_id = webhook.async_generate_id()
            name = user_input[CONF_NAME].strip()
            if name.casefold() == DEFAULT_NAME.casefold():
                name = ""
            elif name.casefold().startswith(f"{DEFAULT_NAME} ".casefold()):
                name = name[len(DEFAULT_NAME) :].strip()
            return self.async_create_entry(
                title=" ".join(part for part in (DEFAULT_NAME, name) if part),
                data={CONF_WEBHOOK_ID: webhook_id},
                options={CONF_TIMEOUT: DEFAULT_TIMEOUT},
                description_placeholders={
                    "webhook_url": _webhook_url(self.hass, webhook_id)
                },
            )

        return self.async_show_form(
            step_id="user",
            data_schema=vol.Schema(
                {vol.Required(CONF_NAME, default=""): str}
            ),
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        """Return the options flow."""
        return TeamsStatusOptionsFlow()


class TeamsStatusOptionsFlow(OptionsFlow):
    """Show the webhook URL and change the timeout."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Manage the options."""
        if user_input is not None:
            return self.async_create_entry(
                data={CONF_TIMEOUT: int(user_input[CONF_TIMEOUT])}
            )

        schema = vol.Schema(
            {
                vol.Required(CONF_TIMEOUT): NumberSelector(
                    NumberSelectorConfig(
                        min=0,
                        max=3600,
                        step=10,
                        unit_of_measurement="s",
                        mode=NumberSelectorMode.BOX,
                    )
                )
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(
                schema,
                {CONF_TIMEOUT: self.config_entry.options.get(CONF_TIMEOUT, DEFAULT_TIMEOUT)},
            ),
            description_placeholders={
                "webhook_url": _webhook_url(
                    self.hass, self.config_entry.data[CONF_WEBHOOK_ID]
                )
            },
        )
=======
"""Config flow for the Teams Busy Light integration."""

from __future__ import annotations

from typing import Any

import voluptuous as vol

from homeassistant.components import webhook
from homeassistant.config_entries import (
    ConfigEntry,
    ConfigFlow,
    ConfigFlowResult,
    OptionsFlow,
)
from homeassistant.const import CONF_NAME, CONF_WEBHOOK_ID
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.network import NoURLAvailableError
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    NumberSelectorMode,
)

from .const import CONF_TIMEOUT, DEFAULT_NAME, DEFAULT_TIMEOUT, DOMAIN


def _webhook_url(hass: HomeAssistant, webhook_id: str) -> str:
    """Return the URL the Windows script has to post to."""
    try:
        return webhook.async_generate_url(hass, webhook_id)
    except NoURLAvailableError:
        return f"https://<your-home-assistant>{webhook.async_generate_path(webhook_id)}"


class TeamsStatusConfigFlow(ConfigFlow, domain=DOMAIN):
    """Create a webhook that receives the Teams status."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Handle the initial step."""
        if user_input is not None:
            webhook_id = webhook.async_generate_id()
            name = user_input[CONF_NAME].strip()
            if name.casefold() == DEFAULT_NAME.casefold():
                name = ""
            elif name.casefold().startswith(f"{DEFAULT_NAME} ".casefold()):
                name = name[len(DEFAULT_NAME) :].strip()
            return self.async_create_entry(
                title=" ".join(part for part in (DEFAULT_NAME, name) if part),
                data={CONF_WEBHOOK_ID: webhook_id},
                options={CONF_TIMEOUT: DEFAULT_TIMEOUT},
                description_placeholders={
                    "webhook_url": _webhook_url(self.hass, webhook_id)
                },
            )

        return self.async_show_form(
            step_id="user",
            data_schema=vol.Schema(
                {vol.Required(CONF_NAME, default=""): str}
            ),
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        """Return the options flow."""
        return TeamsStatusOptionsFlow()


class TeamsStatusOptionsFlow(OptionsFlow):
    """Show the webhook URL and change the timeout."""

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        """Manage the options."""
        if user_input is not None:
            return self.async_create_entry(
                data={CONF_TIMEOUT: int(user_input[CONF_TIMEOUT])}
            )

        schema = vol.Schema(
            {
                vol.Required(CONF_TIMEOUT): NumberSelector(
                    NumberSelectorConfig(
                        min=0,
                        max=3600,
                        step=10,
                        unit_of_measurement="s",
                        mode=NumberSelectorMode.BOX,
                    )
                )
            }
        )
        return self.async_show_form(
            step_id="init",
            data_schema=self.add_suggested_values_to_schema(
                schema,
                {CONF_TIMEOUT: self.config_entry.options.get(CONF_TIMEOUT, DEFAULT_TIMEOUT)},
            ),
            description_placeholders={
                "webhook_url": _webhook_url(
                    self.hass, self.config_entry.data[CONF_WEBHOOK_ID]
                )
            },
        )
>>>>>>> b9d542111a29b60513cdb592535e8745e562db0a
