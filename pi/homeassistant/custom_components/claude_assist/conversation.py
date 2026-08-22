"""The Claude conversation agent.

Claude is given Home Assistant's own LLM tool API, so it controls real devices
through the same permission-checked path the built-in Assist agent uses. Nothing
here talks to the device layer directly.
"""
from __future__ import annotations

import inspect
import json
import logging
from typing import Any

import anthropic
from voluptuous_openapi import convert

from homeassistant.components import conversation
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import MATCH_ALL
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers import intent, llm, template
from homeassistant.helpers.entity_platform import AddEntitiesCallback

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
    MAX_HISTORY_TURNS,
)

LOGGER = logging.getLogger(__name__)

# Guards against a tool loop that never converges. Eight rounds is far more than
# any real request needs ("turn off every light downstairs" is one round).
MAX_TOOL_ROUNDS = 8


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    async_add_entities([ClaudeConversationEntity(entry)])


def _build_llm_context(**kwargs: Any) -> llm.LLMContext:
    """Construct an LLMContext using only the fields this HA version accepts.

    Home Assistant has added and removed LLMContext fields across releases;
    filtering by the actual signature keeps the integration working on more
    versions than hard-coding one field list would.
    """
    try:
        accepted = set(inspect.signature(llm.LLMContext).parameters)
    except (TypeError, ValueError):
        accepted = set(kwargs)
    return llm.LLMContext(**{k: v for k, v in kwargs.items() if k in accepted})


def _format_tool(tool: llm.Tool, custom_serializer: Any) -> dict[str, Any]:
    """Convert one Home Assistant tool into an Anthropic tool definition."""
    schema = convert(tool.parameters, custom_serializer=custom_serializer)
    if not isinstance(schema, dict) or schema.get("type") != "object":
        # The API requires an object schema; a tool that takes no arguments can
        # convert to something looser than that.
        schema = {"type": "object", "properties": {}}
    schema.setdefault("properties", {})
    return {
        "name": tool.name,
        "description": tool.description or "",
        "input_schema": schema,
    }


def _text_of(message: Any) -> str:
    """Join the visible text blocks of a response, ignoring thinking blocks."""
    return "".join(
        block.text for block in message.content if getattr(block, "type", None) == "text"
    ).strip()


class ClaudeConversationEntity(conversation.ConversationEntity, conversation.AbstractConversationAgent):
    """A conversation agent backed by Claude."""

    _attr_has_entity_name = True
    _attr_name = None

    def __init__(self, entry: ConfigEntry) -> None:
        self.entry = entry
        self._history: dict[str, list[dict[str, Any]]] = {}
        self._attr_unique_id = entry.entry_id
        self._attr_device_info = {
            "identifiers": {(DOMAIN, entry.entry_id)},
            "name": entry.title,
            "manufacturer": "Anthropic",
            "model": entry.options.get(CONF_MODEL, DEFAULT_MODEL),
            "entry_type": "service",
        }

    @property
    def supported_languages(self) -> list[str] | str:
        # Claude handles language selection itself; HA does not need to filter.
        return MATCH_ALL

    async def async_added_to_hass(self) -> None:
        await super().async_added_to_hass()
        conversation.async_set_agent(self.hass, self.entry, self)

    async def async_will_remove_from_hass(self) -> None:
        conversation.async_unset_agent(self.hass, self.entry)
        await super().async_will_remove_from_hass()

    # ------------------------------------------------------------------ prompt
    def _render_prompt(self, raw: str) -> str:
        """Render the user's prompt template, falling back to the raw text."""
        try:
            return template.Template(raw, self.hass).async_render(
                {"ha_name": self.hass.config.location_name}, parse_result=False
            )
        except Exception:  # noqa: BLE001 - a broken template must not break voice
            LOGGER.warning("Claude Assist: prompt template failed to render; using it as plain text")
            return raw

    # ----------------------------------------------------------------- entry point
    async def async_process(
        self, user_input: conversation.ConversationInput
    ) -> conversation.ConversationResult:
        options = self.entry.options
        client: anthropic.AsyncAnthropic = self.entry.runtime_data

        conversation_id = user_input.conversation_id or f"claude-{id(user_input):x}"
        intent_response = intent.IntentResponse(language=user_input.language)

        # ------------------------------------------------------------ HA tools
        llm_api = None
        tools: list[dict[str, Any]] = []
        api_id = options.get(CONF_LLM_HASS_API, llm.LLM_API_ASSIST)
        # The options flow offers "none" to turn device control off; it is a
        # plain string, so it has to be checked explicitly rather than by
        # truthiness.
        if api_id in ("none", None, ""):
            api_id = None

        if api_id:
            llm_context = _build_llm_context(
                platform=DOMAIN,
                context=user_input.context,
                user_prompt=user_input.text,
                language=user_input.language,
                assistant=conversation.DOMAIN,
                device_id=user_input.device_id,
            )
            try:
                llm_api = await llm.async_get_api(self.hass, api_id, llm_context)
                tools = [_format_tool(tool, llm_api.custom_serializer) for tool in llm_api.tools]
            except (HomeAssistantError, ValueError) as err:
                LOGGER.error("Claude Assist: could not load the Home Assistant tool API: %s", err)
                intent_response.async_set_error(
                    intent.IntentResponseErrorCode.UNKNOWN,
                    "I could not reach the smart home controls.",
                )
                return conversation.ConversationResult(
                    response=intent_response, conversation_id=conversation_id
                )

        # ----------------------------------------------------------- system prompt
        prompt_parts = [self._render_prompt(options.get(CONF_PROMPT, DEFAULT_PROMPT))]
        if llm_api is not None:
            prompt_parts.append(llm_api.api_prompt)
        system_prompt = "\n\n".join(part for part in prompt_parts if part)

        # --------------------------------------------------------------- history
        messages = list(self._history.get(conversation_id, []))
        messages.append({"role": "user", "content": user_input.text})

        request: dict[str, Any] = {
            "model": options.get(CONF_MODEL, DEFAULT_MODEL),
            "max_tokens": options.get(CONF_MAX_TOKENS, DEFAULT_MAX_TOKENS),
            "system": system_prompt,
            # Thinking stays adaptive; depth is traded for speed via effort.
            "thinking": {"type": "adaptive"},
            "output_config": {"effort": options.get(CONF_EFFORT, DEFAULT_EFFORT)},
        }
        if tools:
            request["tools"] = tools

        # ------------------------------------------------------------- tool loop
        try:
            for _ in range(MAX_TOOL_ROUNDS):
                response = await client.messages.create(messages=messages, **request)

                if response.stop_reason == "refusal":
                    intent_response.async_set_error(
                        intent.IntentResponseErrorCode.UNKNOWN,
                        "Sorry, I can't help with that one.",
                    )
                    return conversation.ConversationResult(
                        response=intent_response, conversation_id=conversation_id
                    )

                # Echo the assistant turn back verbatim — thinking blocks must be
                # replayed unchanged for the model to continue its own reasoning.
                messages.append({"role": "assistant", "content": response.content})

                tool_uses = [b for b in response.content if getattr(b, "type", None) == "tool_use"]
                if not tool_uses:
                    break

                results = []
                for block in tool_uses:
                    results.append(await self._run_tool(llm_api, block))
                # All results for one assistant turn go back in a single user
                # message; splitting them suppresses future parallel tool calls.
                messages.append({"role": "user", "content": results})
            else:
                LOGGER.warning("Claude Assist: stopped after %s tool rounds", MAX_TOOL_ROUNDS)

        except anthropic.AuthenticationError:
            intent_response.async_set_error(
                intent.IntentResponseErrorCode.UNKNOWN,
                "My Anthropic API key was rejected. Check it in settings.",
            )
            return conversation.ConversationResult(
                response=intent_response, conversation_id=conversation_id
            )
        except anthropic.RateLimitError:
            intent_response.async_set_error(
                intent.IntentResponseErrorCode.UNKNOWN,
                "I'm being rate limited right now. Try again in a moment.",
            )
            return conversation.ConversationResult(
                response=intent_response, conversation_id=conversation_id
            )
        except anthropic.APIError as err:
            LOGGER.error("Claude Assist: Anthropic API error: %s", err)
            intent_response.async_set_error(
                intent.IntentResponseErrorCode.UNKNOWN,
                "I couldn't reach Claude just now.",
            )
            return conversation.ConversationResult(
                response=intent_response, conversation_id=conversation_id
            )

        # ---------------------------------------------------------------- reply
        speech = _text_of(response) or "Done."
        self._history[conversation_id] = messages[-(MAX_HISTORY_TURNS * 2):]
        intent_response.async_set_speech(speech)
        return conversation.ConversationResult(
            response=intent_response, conversation_id=conversation_id
        )

    async def _run_tool(self, llm_api: Any, block: Any) -> dict[str, Any]:
        """Execute one Home Assistant tool call and shape the result block."""
        if llm_api is None:
            return {
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": "No smart home tools are available.",
                "is_error": True,
            }
        try:
            tool_input = llm.ToolInput(tool_name=block.name, tool_args=dict(block.input))
            result = await llm_api.async_call_tool(tool_input)
            payload = json.dumps(result, default=str)
        except Exception as err:  # noqa: BLE001 - report failure to the model
            LOGGER.warning("Claude Assist: tool %s failed: %s", block.name, err)
            return {
                "type": "tool_result",
                "tool_use_id": block.id,
                "content": f"Tool failed: {err}",
                "is_error": True,
            }
        return {"type": "tool_result", "tool_use_id": block.id, "content": payload}
