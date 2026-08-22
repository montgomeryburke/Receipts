"""Config and options flow for Claude Assist."""
from __future__ import annotations

import logging
from typing import Any

import anthropic
import voluptuous as vol

from homeassistant.config_entries import ConfigEntry, ConfigFlow, ConfigFlowResult, OptionsFlow
from homeassistant.const import CONF_API_KEY
from homeassistant.core import HomeAssistant
from homeassistant.helpers import llm
from homeassistant.helpers.selector import (
    NumberSelector,
    NumberSelectorConfig,
    SelectOptionDict,
    SelectSelector,
    SelectSelectorConfig,
    SelectSelectorMode,
    TemplateSelector,
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from .const import (
    CONF_EFFORT,
    CONF_LLM_HASS_API,
    CONF_MAX_TOKENS,
    CONF_MODEL,
    CONF_PROMPT,
    DEFAULT_EFFORT,
    DEFAULT_MAX_TOKENS,
    DEFAULT_MODEL,
    DEFAULT_PROMPT,
    DOMAIN,
    EFFORT_LEVELS,
)

LOGGER = logging.getLogger(__name__)

STEP_USER_SCHEMA = vol.Schema({vol.Required(CONF_API_KEY): str})


async def validate_api_key(hass: HomeAssistant, api_key: str) -> None:
    """Raise if the key cannot list models."""
    client = anthropic.AsyncAnthropic(api_key=api_key)
    await client.models.list(limit=1)


class ClaudeAssistConfigFlow(ConfigFlow, domain=DOMAIN):
    """Ask for an API key, once."""

    VERSION = 1

    async def async_step_user(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        errors: dict[str, str] = {}

        if user_input is not None:
            try:
                await validate_api_key(self.hass, user_input[CONF_API_KEY])
            except anthropic.AuthenticationError:
                errors["base"] = "invalid_auth"
            except anthropic.APIConnectionError:
                errors["base"] = "cannot_connect"
            except anthropic.APIError as err:
                LOGGER.error("Claude Assist: unexpected API error: %s", err)
                errors["base"] = "unknown"
            else:
                return self.async_create_entry(
                    title="Claude Assist",
                    data={CONF_API_KEY: user_input[CONF_API_KEY]},
                    options={
                        CONF_MODEL: DEFAULT_MODEL,
                        CONF_PROMPT: DEFAULT_PROMPT,
                        CONF_MAX_TOKENS: DEFAULT_MAX_TOKENS,
                        CONF_EFFORT: DEFAULT_EFFORT,
                        CONF_LLM_HASS_API: llm.LLM_API_ASSIST,
                    },
                )

        return self.async_show_form(
            step_id="user", data_schema=STEP_USER_SCHEMA, errors=errors
        )

    @staticmethod
    def async_get_options_flow(config_entry: ConfigEntry) -> OptionsFlow:
        return ClaudeAssistOptionsFlow(config_entry)


class ClaudeAssistOptionsFlow(OptionsFlow):
    """Tune the model, prompt, and how much it is allowed to control."""

    def __init__(self, config_entry: ConfigEntry) -> None:
        # Stored under a private name: assigning self.config_entry is
        # deprecated in current Home Assistant releases.
        self._entry = config_entry

    async def async_step_init(
        self, user_input: dict[str, Any] | None = None
    ) -> ConfigFlowResult:
        if user_input is not None:
            return self.async_create_entry(title="", data=user_input)

        options = self._entry.options
        apis: list[SelectOptionDict] = [
            SelectOptionDict(label="No device control", value="none")
        ]
        apis.extend(
            SelectOptionDict(label=api.name, value=api.id)
            for api in llm.async_get_apis(self.hass)
        )

        schema = vol.Schema(
            {
                vol.Optional(
                    CONF_PROMPT, default=options.get(CONF_PROMPT, DEFAULT_PROMPT)
                ): TemplateSelector(),
                vol.Optional(
                    CONF_LLM_HASS_API,
                    default=options.get(CONF_LLM_HASS_API, llm.LLM_API_ASSIST),
                ): SelectSelector(
                    SelectSelectorConfig(options=apis, mode=SelectSelectorMode.DROPDOWN)
                ),
                vol.Optional(
                    CONF_MODEL, default=options.get(CONF_MODEL, DEFAULT_MODEL)
                ): TextSelector(TextSelectorConfig(type=TextSelectorType.TEXT)),
                vol.Optional(
                    CONF_EFFORT, default=options.get(CONF_EFFORT, DEFAULT_EFFORT)
                ): SelectSelector(
                    SelectSelectorConfig(
                        options=[
                            SelectOptionDict(label=level, value=level)
                            for level in EFFORT_LEVELS
                        ],
                        mode=SelectSelectorMode.DROPDOWN,
                    )
                ),
                vol.Optional(
                    CONF_MAX_TOKENS,
                    default=options.get(CONF_MAX_TOKENS, DEFAULT_MAX_TOKENS),
                ): NumberSelector(NumberSelectorConfig(min=128, max=8192, step=64)),
            }
        )
        return self.async_show_form(step_id="init", data_schema=schema)
