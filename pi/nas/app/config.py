"""Runtime configuration for the pi-nas file server.

Every value is read from the environment so that systemd can supply them from
/etc/pi-nas/config.env without the code needing to know where it lives.
"""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_ROOT = "/srv/nas"
DEFAULT_TOKENS = "/etc/pi-nas/tokens.json"


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _list_env(name: str) -> list[str]:
    raw = os.environ.get(name, "")
    return [item.strip() for item in raw.split(",") if item.strip()]


@dataclass(frozen=True)
class Settings:
    #: Directory that is exposed over the API. Nothing outside it is reachable.
    root: Path = field(default_factory=lambda: Path(os.environ.get("PI_NAS_ROOT", DEFAULT_ROOT)))
    #: JSON file holding hashed access tokens.
    tokens_file: Path = field(
        default_factory=lambda: Path(os.environ.get("PI_NAS_TOKENS_FILE", DEFAULT_TOKENS))
    )
    #: Largest single upload accepted, in bytes. 0 disables the limit.
    max_upload_bytes: int = field(
        default_factory=lambda: _int_env("PI_NAS_MAX_UPLOAD_BYTES", 20 * 1024**3)
    )
    #: Bytes moved per read/write when streaming file bodies.
    chunk_bytes: int = field(default_factory=lambda: _int_env("PI_NAS_CHUNK_BYTES", 1024 * 1024))
    #: Extra browser origins allowed to call the API. Extension origins are
    #: matched by the chrome-extension:// scheme check in app.py instead.
    extra_origins: list[str] = field(default_factory=lambda: _list_env("PI_NAS_EXTRA_ORIGINS"))
    #: Extension IDs allowed to call the API. Empty means "any extension that
    #: presents a valid token", which is still token-gated.
    allowed_extension_ids: list[str] = field(
        default_factory=lambda: _list_env("PI_NAS_ALLOWED_EXTENSION_IDS")
    )


def load_settings() -> Settings:
    return Settings()
