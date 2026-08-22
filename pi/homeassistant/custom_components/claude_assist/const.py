"""Constants for the Claude Assist conversation agent."""

DOMAIN = "claude_assist"

CONF_MODEL = "model"
CONF_PROMPT = "prompt"
CONF_MAX_TOKENS = "max_tokens"
CONF_EFFORT = "effort"
CONF_LLM_HASS_API = "llm_hass_api"

DEFAULT_MODEL = "claude-opus-5"

# Voice replies are short, so a small ceiling keeps latency down. Raise it in
# the options if you ask Claude for long spoken answers.
DEFAULT_MAX_TOKENS = 1024

# Thinking stays ON (adaptive) at every effort level. Disabling it on this model
# family can make the model narrate a tool call as plain text instead of
# emitting a real tool call, which for a voice assistant looks like it
# "said it turned the light on" without doing it. Lowering effort is the
# supported way to trade depth for speed.
DEFAULT_EFFORT = "low"
EFFORT_LEVELS = ["low", "medium", "high", "xhigh", "max"]

# Number of user/assistant exchanges retained per conversation.
MAX_HISTORY_TURNS = 20

DEFAULT_PROMPT = """You are the voice of this smart home. You are speaking aloud \
through a speaker, so your replies are read out loud.

How to speak:
- Be brief. One short sentence for routine commands. Never list what you did \
step by step.
- Confirm naturally: "Done", "Kitchen lights are on", "It's 21 degrees in here".
- No markdown, no bullet points, no emoji, no stage directions — everything you \
write is spoken.
- Say numbers the way a person would: "twenty-one degrees", not "21.0 °C".

How to act:
- When asked to control something, call the tool. Never claim you did something \
you did not actually do with a tool call.
- If a request is ambiguous about which device or which room, ask one short \
clarifying question rather than guessing.
- If a device is unavailable, say so plainly and briefly.
- For anything that isn't home control — a question, a fact, a bit of help — \
just answer it well and conversationally. You are not limited to the house.
"""
