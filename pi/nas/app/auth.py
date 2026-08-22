"""Bearer-token authentication.

Tokens are 256-bit random strings shown to the user exactly once. Only their
SHA-256 digests are stored, so a stolen tokens.json does not yield usable
credentials. Because the tokens carry full entropy, a plain digest is
appropriate here — a slow KDF guards low-entropy secrets, which these are not.
"""
from __future__ import annotations

import hashlib
import json
import secrets
import time
from dataclasses import dataclass
from pathlib import Path

TOKEN_PREFIX = "pinas_"


def generate_token() -> str:
    return TOKEN_PREFIX + secrets.token_urlsafe(32)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class TokenRecord:
    id: str
    name: str
    hash: str
    scopes: tuple[str, ...]
    created: float

    def can(self, scope: str) -> bool:
        return scope in self.scopes


class TokenStore:
    """Reads tokens.json, reloading it whenever the file changes on disk.

    Reloading on mtime means ``pi-nas-token revoke`` takes effect immediately,
    with no service restart.
    """

    def __init__(self, path: Path) -> None:
        self.path = path
        self._records: list[TokenRecord] = []
        self._mtime: float | None = None
        self._load()

    def _load(self) -> None:
        try:
            stamp = self.path.stat().st_mtime
        except OSError:
            self._records = []
            self._mtime = None
            return
        if self._mtime is not None and stamp == self._mtime:
            return
        try:
            raw = json.loads(self.path.read_text("utf-8") or "{}")
        except (OSError, json.JSONDecodeError):
            # A malformed file must fail closed: no tokens means no access,
            # rather than falling back to a previously loaded set.
            self._records = []
            self._mtime = stamp
            return
        records = []
        for item in raw.get("tokens", []):
            try:
                records.append(
                    TokenRecord(
                        id=str(item["id"]),
                        name=str(item.get("name", "")),
                        hash=str(item["hash"]),
                        scopes=tuple(item.get("scopes", ["read", "write"])),
                        created=float(item.get("created", 0)),
                    )
                )
            except (KeyError, TypeError, ValueError):
                continue
        self._records = records
        self._mtime = stamp

    def verify(self, token: str) -> TokenRecord | None:
        """Return the matching record, or None. Constant-time per candidate."""
        self._load()
        if not token:
            return None
        digest = hash_token(token)
        matched: TokenRecord | None = None
        for record in self._records:
            # Compare every record so timing does not reveal the position of a
            # match; the loop body is constant work per record.
            if secrets.compare_digest(digest, record.hash):
                matched = record
        return matched

    def is_empty(self) -> bool:
        self._load()
        return not self._records


def write_store(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"tokens": records}, indent=2) + "\n"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(payload, "utf-8")
    tmp.chmod(0o600)
    tmp.replace(path)


def read_store(path: Path) -> list[dict]:
    try:
        return json.loads(path.read_text("utf-8") or "{}").get("tokens", [])
    except (OSError, json.JSONDecodeError):
        return []


def add_token(path: Path, name: str, scopes: list[str]) -> str:
    token = generate_token()
    records = read_store(path)
    records.append(
        {
            "id": secrets.token_hex(4),
            "name": name,
            "hash": hash_token(token),
            "scopes": scopes,
            "created": time.time(),
        }
    )
    write_store(path, records)
    return token
