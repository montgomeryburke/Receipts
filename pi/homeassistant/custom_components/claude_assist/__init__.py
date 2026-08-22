"""Claude Assist — a Claude-powered conversation agent for Home Assistant."""
from __future__ import annotations

import anthropic

from homeassistant.config_entries import ConfigEntry
from homeassistant.const import CONF_API_KEY, Platform
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import ConfigEntryAuthFailed, ConfigEntryNotReady

from .const import DOMAIN

PLATFORMS: list[Platform] = [Platform.CONVERSATION]


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Create the shared Anthropic client and verify the key still works."""
    client = anthropic.AsyncAnthropic(api_key=entry.data[CONF_API_KEY])

    try:
        # A models lookup is the cheapest call that proves the key is valid.
        await client.models.list(limit=1)
    except anthropic.AuthenticationError as err:
        raise ConfigEntryAuthFailed("Anthropic API key was rejected") from err
    except anthropic.APIError as err:
        raise ConfigEntryNotReady(f"Could not reach the Anthropic API: {err}") from err

    entry.runtime_data = client
    hass.data.setdefault(DOMAIN, {})[entry.entry_id] = client

    await hass.config_entries.async_forward_entry_setups(entry, PLATFORMS)
    entry.async_on_unload(entry.add_update_listener(async_reload_entry))
    return True


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    unloaded = await hass.config_entries.async_unload_platforms(entry, PLATFORMS)
    if unloaded:
        hass.data.get(DOMAIN, {}).pop(entry.entry_id, None)
    return unloaded


async def async_reload_entry(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Options changed — reload so the new prompt/model take effect."""
    await hass.config_entries.async_reload(entry.entry_id)
