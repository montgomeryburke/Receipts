"""Tests for the pi-nas API.

Focus is on the two things most likely to be catastrophic if wrong: path
containment and authentication. The happy-path file operations are covered too,
since a NAS that corrupts uploads is worse than one that refuses them.
"""
from __future__ import annotations

import json
import time as time_module
import os
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


@pytest.fixture()
def client(tmp_path, monkeypatch):
    share = tmp_path / "share"
    share.mkdir()
    tokens_file = tmp_path / "tokens.json"

    from app.auth import hash_token

    tokens_file.write_text(
        json.dumps(
            {
                "tokens": [
                    {"id": "rw", "name": "full", "hash": hash_token("tok-rw"),
                     "scopes": ["read", "write"], "created": 0},
                    {"id": "ro", "name": "readonly", "hash": hash_token("tok-ro"),
                     "scopes": ["read"], "created": 0},
                ]
            }
        )
    )

    monkeypatch.setenv("PI_NAS_ROOT", str(share))
    monkeypatch.setenv("PI_NAS_TOKENS_FILE", str(tokens_file))

    # Reimport so module-level settings pick up the patched environment.
    for name in [m for m in list(sys.modules) if m == "app" or m.startswith("app.")]:
        del sys.modules[name]
    from app.main import app as fastapi_app

    with TestClient(fastapi_app) as test_client:
        test_client.share = share
        yield test_client


def auth(token="tok-rw"):
    return {"Authorization": f"Bearer {token}"}


# --------------------------------------------------------------------- auth
def test_health_needs_no_token(client):
    assert client.get("/api/health").json()["ok"] is True


def test_list_rejects_missing_token(client):
    assert client.get("/api/list").status_code == 401


def test_list_rejects_bad_token(client):
    assert client.get("/api/list", headers=auth("nope")).status_code == 401


def test_read_only_token_cannot_write(client):
    response = client.post("/api/mkdir", json={"path": "x"}, headers=auth("tok-ro"))
    assert response.status_code == 403


def test_read_only_token_can_read(client):
    assert client.get("/api/list", headers=auth("tok-ro")).status_code == 200


def test_revoking_a_token_takes_effect_without_restart(client, tmp_path):
    assert client.get("/api/list", headers=auth()).status_code == 200
    tokens_file = tmp_path / "tokens.json"
    tokens_file.write_text(json.dumps({"tokens": []}))
    os.utime(tokens_file, (0, 0))  # force a distinct mtime
    assert client.get("/api/list", headers=auth()).status_code == 401


def test_malformed_tokens_file_fails_closed(client, tmp_path):
    tokens_file = tmp_path / "tokens.json"
    tokens_file.write_text("{ this is not json")
    os.utime(tokens_file, (0, 0))
    assert client.get("/api/list", headers=auth()).status_code == 401


# ---------------------------------------------------------- path containment
@pytest.mark.parametrize(
    "attack",
    [
        "../../../../etc/passwd",
        "..",
        "foo/../../..",
        "....//....//etc/passwd",
        "..\\..\\windows",
        "/etc/passwd",
        "C:/Windows",
    ],
)
def test_traversal_attempts_never_escape(client, attack):
    response = client.get("/api/list", params={"path": attack}, headers=auth())
    assert response.status_code in (400, 404), attack


def test_absolute_path_is_treated_as_relative_not_absolute(client):
    (client.share / "etc").mkdir()
    (client.share / "etc" / "passwd").write_text("inside the share")
    response = client.get("/api/stat", params={"path": "/etc/passwd"}, headers=auth())
    assert response.status_code == 200
    assert response.json()["path"] == "etc/passwd"


def test_symlink_out_of_share_is_rejected(client, tmp_path):
    secret = tmp_path / "secret.txt"
    secret.write_text("do not leak")
    (client.share / "escape").symlink_to(secret)
    response = client.get("/api/download", params={"path": "escape"}, headers=auth())
    assert response.status_code == 400


def test_null_byte_rejected(client):
    response = client.get("/api/stat", params={"path": "a\x00b"}, headers=auth())
    assert response.status_code == 400


def test_cannot_delete_share_root(client):
    response = client.post("/api/delete", json={"path": ""}, headers=auth())
    assert response.status_code == 400
    assert client.share.exists()


# ------------------------------------------------------------ file operations
def test_upload_download_roundtrip(client):
    payload = os.urandom(200_000)
    put = client.put("/api/upload", params={"path": "docs/blob.bin"}, content=payload,
                     headers=auth())
    assert put.status_code == 200
    assert put.json()["size"] == len(payload)

    got = client.get("/api/download", params={"path": "docs/blob.bin"}, headers=auth())
    assert got.status_code == 200
    assert got.content == payload


def test_upload_creates_parent_directories(client):
    client.put("/api/upload", params={"path": "a/b/c/deep.txt"}, content=b"hi", headers=auth())
    assert (client.share / "a" / "b" / "c" / "deep.txt").read_bytes() == b"hi"


def test_upload_without_overwrite_keeps_both_copies(client):
    client.put("/api/upload", params={"path": "note.txt"}, content=b"first", headers=auth())
    second = client.put("/api/upload", params={"path": "note.txt"}, content=b"second",
                        headers=auth())
    assert second.json()["path"] == "note (2).txt"
    assert (client.share / "note.txt").read_bytes() == b"first"


def test_upload_with_overwrite_replaces(client):
    client.put("/api/upload", params={"path": "note.txt"}, content=b"first", headers=auth())
    client.put("/api/upload", params={"path": "note.txt", "overwrite": "true"},
               content=b"second", headers=auth())
    assert (client.share / "note.txt").read_bytes() == b"second"


def test_no_part_files_left_behind(client):
    client.put("/api/upload", params={"path": "clean.bin"}, content=b"x" * 1000, headers=auth())
    assert list(client.share.glob("*.pinas-part")) == []


def test_multipart_upload(client):
    response = client.post(
        "/api/upload",
        files={"file": ("report.txt", b"multipart body", "text/plain")},
        data={"path": "reports"},
        headers=auth(),
    )
    assert response.status_code == 200
    assert (client.share / "reports" / "report.txt").read_bytes() == b"multipart body"


def test_multipart_filename_is_stripped_of_directories(client):
    client.post(
        "/api/upload",
        files={"file": ("../../evil.txt", b"nope", "text/plain")},
        data={"path": ""},
        headers=auth(),
    )
    assert (client.share / "evil.txt").exists()


def test_range_request_returns_partial_content(client):
    client.put("/api/upload", params={"path": "r.bin"}, content=b"0123456789", headers=auth())
    response = client.get("/api/download", params={"path": "r.bin"},
                          headers={**auth(), "Range": "bytes=2-5"})
    assert response.status_code == 206
    assert response.content == b"2345"
    assert response.headers["Content-Range"] == "bytes 2-5/10"


def test_suffix_range(client):
    client.put("/api/upload", params={"path": "r.bin"}, content=b"0123456789", headers=auth())
    response = client.get("/api/download", params={"path": "r.bin"},
                          headers={**auth(), "Range": "bytes=-3"})
    assert response.status_code == 206
    assert response.content == b"789"


def test_unsatisfiable_range(client):
    client.put("/api/upload", params={"path": "r.bin"}, content=b"0123", headers=auth())
    response = client.get("/api/download", params={"path": "r.bin"},
                          headers={**auth(), "Range": "bytes=99-"})
    assert response.status_code == 416


def test_listing_sorts_directories_first(client):
    (client.share / "zebra").mkdir()
    (client.share / "apple.txt").write_text("a")
    names = [e["name"] for e in client.get("/api/list", headers=auth()).json()["entries"]]
    assert names == ["zebra", "apple.txt"]


def test_hidden_files_excluded_by_default(client):
    (client.share / ".secret").write_text("x")
    (client.share / "visible.txt").write_text("x")
    entries = client.get("/api/list", headers=auth()).json()["entries"]
    assert [e["name"] for e in entries] == ["visible.txt"]

    entries = client.get("/api/list", params={"hidden": "true"}, headers=auth()).json()["entries"]
    assert ".secret" in [e["name"] for e in entries]


def test_mkdir_move_delete(client):
    client.post("/api/mkdir", json={"path": "projects/claude"}, headers=auth())
    assert (client.share / "projects" / "claude").is_dir()

    client.put("/api/upload", params={"path": "projects/claude/a.txt"}, content=b"a", headers=auth())
    client.post("/api/move", json={"src": "projects/claude/a.txt", "dst": "projects/b.txt"},
                headers=auth())
    assert (client.share / "projects" / "b.txt").exists()

    client.post("/api/delete", json={"path": "projects", "recursive": True}, headers=auth())
    assert not (client.share / "projects").exists()


def test_delete_nonempty_directory_requires_recursive(client):
    client.post("/api/mkdir", json={"path": "full"}, headers=auth())
    client.put("/api/upload", params={"path": "full/x.txt"}, content=b"x", headers=auth())
    response = client.post("/api/delete", json={"path": "full"}, headers=auth())
    assert response.status_code == 400


def test_usage_reports_disk_space(client):
    body = client.get("/api/usage", headers=auth()).json()
    assert body["total"] > 0 and body["free"] >= 0


# ----------------------------------------------------------------------- CORS
def test_extension_origin_gets_cors_headers(client):
    origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
    response = client.get("/api/health", headers={"Origin": origin})
    assert response.headers.get("Access-Control-Allow-Origin") == origin


def test_random_website_gets_no_cors_headers(client):
    response = client.get("/api/health", headers={"Origin": "https://evil.example"})
    assert "Access-Control-Allow-Origin" not in response.headers


def test_preflight_from_extension_allowed(client):
    origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop"
    response = client.options(
        "/api/list",
        headers={"Origin": origin, "Access-Control-Request-Method": "GET"},
    )
    assert response.status_code == 204
    assert "Authorization" in response.headers["Access-Control-Allow-Headers"]


def test_preflight_from_website_refused(client):
    response = client.options(
        "/api/list",
        headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"},
    )
    assert response.status_code == 403


# -------------------------------------------------------------------- tickets
def test_ticket_allows_download_without_auth_header(client):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"ticketed", headers=auth())
    ticket = client.post("/api/ticket", json={"path": "t.bin"}, headers=auth()).json()["ticket"]
    response = client.get("/api/download", params={"path": "t.bin", "ticket": ticket})
    assert response.status_code == 200
    assert response.content == b"ticketed"


def test_ticket_is_single_use(client):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"x", headers=auth())
    ticket = client.post("/api/ticket", json={"path": "t.bin"}, headers=auth()).json()["ticket"]
    client.get("/api/download", params={"path": "t.bin", "ticket": ticket})
    replay = client.get("/api/download", params={"path": "t.bin", "ticket": ticket})
    assert replay.status_code == 401


def test_ticket_is_bound_to_its_own_file(client):
    client.put("/api/upload", params={"path": "mine.bin"}, content=b"a", headers=auth())
    client.put("/api/upload", params={"path": "other.bin"}, content=b"b", headers=auth())
    ticket = client.post("/api/ticket", json={"path": "mine.bin"}, headers=auth()).json()["ticket"]
    response = client.get("/api/download", params={"path": "other.bin", "ticket": ticket})
    assert response.status_code == 401


def test_forged_ticket_rejected(client):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"x", headers=auth())
    response = client.get("/api/download", params={"path": "t.bin", "ticket": "made-up"})
    assert response.status_code == 401


def test_expired_ticket_rejected(client, monkeypatch):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"x", headers=auth())
    ticket = client.post("/api/ticket", json={"path": "t.bin"}, headers=auth()).json()["ticket"]

    import app.main as main

    # Capture the real clock before patching; patching main.time.time patches
    # the shared time module, so a lambda calling time.time() would recurse.
    real_time = time_module.time
    monkeypatch.setattr(main.time, "time", lambda: real_time() + 999)
    response = client.get("/api/download", params={"path": "t.bin", "ticket": ticket})
    assert response.status_code == 401


def test_download_still_requires_auth_without_ticket(client):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"x", headers=auth())
    assert client.get("/api/download", params={"path": "t.bin"}).status_code == 401


def test_ticket_creation_requires_auth(client):
    client.put("/api/upload", params={"path": "t.bin"}, content=b"x", headers=auth())
    assert client.post("/api/ticket", json={"path": "t.bin"}).status_code == 401
