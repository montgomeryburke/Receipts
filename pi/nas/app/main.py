"""pi-nas — a small, token-authenticated file API for a USB drive on a Pi.

Design notes:
  * Every mutating route requires the ``write`` scope; reads require ``read``.
  * Client paths never touch the filesystem without going through
    ``storage.resolve``, which enforces containment under the share root.
  * Uploads stream to a ``.part`` file and are renamed into place only after the
    body is fully received, so an interrupted upload never leaves a truncated
    file at the real name.
"""
from __future__ import annotations

import os
import re
import secrets
import shutil
import time
from pathlib import Path
from typing import Annotated, Iterator

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, UploadFile, File, Form
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel

from .auth import TokenRecord, TokenStore
from .config import Settings, load_settings
from . import storage

settings: Settings = load_settings()
tokens = TokenStore(settings.tokens_file)

app = FastAPI(
    title="pi-nas",
    version="1.0.0",
    description="Token-authenticated file access to a USB drive attached to a Raspberry Pi.",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")

# Short-lived download tickets.
#
# The browser's download manager cannot attach an Authorization header, so a
# native streaming download needs the credential in the URL. A ticket is
# random, expires in two minutes, and is bound to one specific file, which
# makes it far weaker than handing out the real token as a query parameter.
TICKET_TTL_SECONDS = 120
_tickets: dict[str, tuple[str, float]] = {}


def _issue_ticket(path: str) -> str:
    now = time.time()
    for key, (_, expiry) in list(_tickets.items()):
        if expiry < now:
            del _tickets[key]
    ticket = secrets.token_urlsafe(24)
    _tickets[ticket] = (path, now + TICKET_TTL_SECONDS)
    return ticket


def _redeem_ticket(ticket: str, path: str) -> bool:
    """Validate and consume a ticket. Single use, and only for its own path."""
    entry = _tickets.get(ticket)
    if entry is None:
        return False
    ticket_path, expiry = entry
    if expiry < time.time():
        del _tickets[ticket]
        return False
    if not secrets.compare_digest(ticket_path, path):
        return False
    del _tickets[ticket]
    return True


# --------------------------------------------------------------------------
# CORS
# --------------------------------------------------------------------------
def _origin_allowed(origin: str) -> bool:
    if not origin:
        return False
    if origin in settings.extra_origins:
        return True
    if origin.startswith("chrome-extension://"):
        extension_id = origin[len("chrome-extension://") :]
        if not settings.allowed_extension_ids:
            # No allow-list configured: any extension may *attempt* a call, but
            # it still needs a valid token to get anything back.
            return True
        return extension_id in settings.allowed_extension_ids
    return False


@app.middleware("http")
async def cors_middleware(request: Request, call_next):
    origin = request.headers.get("origin", "")
    allowed = _origin_allowed(origin)

    if request.method == "OPTIONS" and "access-control-request-method" in request.headers:
        if not allowed:
            return Response(status_code=403)
        return Response(
            status_code=204,
            headers={
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Overwrite",
                "Access-Control-Max-Age": "600",
                "Vary": "Origin",
            },
        )

    response = await call_next(request)
    if allowed:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Expose-Headers"] = "Content-Length, Content-Range, Content-Disposition"
        response.headers["Vary"] = "Origin"
    return response


# --------------------------------------------------------------------------
# Auth dependencies
# --------------------------------------------------------------------------
def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    return authorization[7:].strip()


def require_read(authorization: Annotated[str | None, Header()] = None) -> TokenRecord:
    record = tokens.verify(_bearer(authorization))
    if record is None or not record.can("read"):
        raise HTTPException(status_code=401, detail="invalid token")
    return record


def require_write(authorization: Annotated[str | None, Header()] = None) -> TokenRecord:
    record = tokens.verify(_bearer(authorization))
    if record is None:
        raise HTTPException(status_code=401, detail="invalid token")
    if not record.can("write"):
        raise HTTPException(status_code=403, detail="token is read-only")
    return record


ReadToken = Annotated[TokenRecord, Depends(require_read)]
WriteToken = Annotated[TokenRecord, Depends(require_write)]


def _resolve(raw: str, *, must_exist: bool = True) -> Path:
    try:
        return storage.resolve(settings.root, raw, must_exist=must_exist)
    except storage.PathError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="not found") from exc


# --------------------------------------------------------------------------
# Request bodies
# --------------------------------------------------------------------------
class PathBody(BaseModel):
    path: str


class DeleteBody(BaseModel):
    path: str
    recursive: bool = False


class MoveBody(BaseModel):
    src: str
    dst: str


# --------------------------------------------------------------------------
# Routes
# --------------------------------------------------------------------------
@app.get("/api/health")
def health() -> dict:
    """Unauthenticated liveness probe — deliberately leaks nothing."""
    return {"ok": True, "service": "pi-nas", "version": app.version}


@app.get("/api/whoami")
def whoami(token: ReadToken) -> dict:
    return {"name": token.name, "id": token.id, "scopes": list(token.scopes)}


@app.get("/api/list")
def list_directory(
    token: ReadToken,
    path: str = Query("", description="Directory relative to the share root"),
    hidden: bool = Query(False),
) -> dict:
    target = _resolve(path)
    if not target.is_dir():
        raise HTTPException(status_code=400, detail="not a directory")
    entries = storage.list_dir(settings.root, target, show_hidden=hidden)
    return {
        "path": storage.relative(settings.root, target),
        "entries": [entry.as_dict() for entry in entries],
    }


@app.get("/api/stat")
def stat_path(token: ReadToken, path: str = Query(...)) -> dict:
    target = _resolve(path)
    info = target.stat()
    return {
        "name": target.name,
        "path": storage.relative(settings.root, target),
        "is_dir": target.is_dir(),
        "size": info.st_size,
        "modified": info.st_mtime,
    }


@app.get("/api/usage")
def usage(token: ReadToken) -> dict:
    return storage.disk_usage(settings.root)


def _file_iterator(path: Path, start: int, length: int, chunk: int) -> Iterator[bytes]:
    with path.open("rb") as handle:
        handle.seek(start)
        remaining = length
        while remaining > 0:
            block = handle.read(min(chunk, remaining))
            if not block:
                break
            remaining -= len(block)
            yield block


@app.post("/api/ticket")
def create_ticket(body: PathBody, token: ReadToken) -> dict:
    """Mint a single-use, 2-minute URL credential for one file."""
    target = _resolve(body.path)
    if target.is_dir():
        raise HTTPException(status_code=400, detail="path is a directory")
    relative_path = storage.relative(settings.root, target)
    return {
        "ticket": _issue_ticket(relative_path),
        "path": relative_path,
        "expires_in": TICKET_TTL_SECONDS,
    }


@app.get("/api/download")
def download(
    path: str = Query(...),
    ticket: str | None = Query(None),
    authorization: Annotated[str | None, Header()] = None,
    range_header: Annotated[str | None, Header(alias="range")] = None,
) -> Response:
    # Two ways in: a bearer token, or a ticket minted for this exact file.
    target = _resolve(path)
    relative_path = storage.relative(settings.root, target)
    if ticket:
        if not _redeem_ticket(ticket, relative_path):
            raise HTTPException(status_code=401, detail="invalid or expired ticket")
    else:
        record = tokens.verify(_bearer(authorization))
        if record is None or not record.can("read"):
            raise HTTPException(status_code=401, detail="invalid token")
    if target.is_dir():
        raise HTTPException(status_code=400, detail="path is a directory")

    size = target.stat().st_size
    start, end = 0, size - 1
    status = 200
    headers = {
        "Accept-Ranges": "bytes",
        "Content-Disposition": f'attachment; filename="{target.name}"',
    }

    if range_header:
        match = RANGE_RE.match(range_header.strip())
        if not match:
            raise HTTPException(status_code=416, detail="malformed range")
        first, last = match.group(1), match.group(2)
        if first:
            start = int(first)
            if last:
                end = min(int(last), size - 1)
        elif last:
            # Suffix range: the final N bytes.
            start = max(size - int(last), 0)
        else:
            raise HTTPException(status_code=416, detail="malformed range")
        if start > end or start >= size:
            return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
        status = 206
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"

    length = 0 if size == 0 else end - start + 1
    headers["Content-Length"] = str(length)
    return StreamingResponse(
        _file_iterator(target, start, length, settings.chunk_bytes),
        status_code=status,
        media_type="application/octet-stream",
        headers=headers,
    )


async def _write_stream(destination: Path, chunks, overwrite: bool) -> dict:
    if destination.exists() and not overwrite:
        destination = storage.unique_destination(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    part = destination.with_name(destination.name + ".pinas-part")
    written = 0
    try:
        with part.open("wb") as handle:
            async for chunk in chunks:
                written += len(chunk)
                if settings.max_upload_bytes and written > settings.max_upload_bytes:
                    raise HTTPException(status_code=413, detail="upload too large")
                handle.write(chunk)
            handle.flush()
            os.fsync(handle.fileno())
        part.replace(destination)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    return {
        "path": storage.relative(settings.root, destination),
        "name": destination.name,
        "size": written,
    }


@app.put("/api/upload")
async def upload_raw(
    request: Request,
    token: WriteToken,
    path: str = Query(..., description="Destination file path"),
    overwrite: bool = Query(False),
) -> dict:
    destination = _resolve(path, must_exist=False)
    if destination.is_dir():
        raise HTTPException(status_code=400, detail="destination is a directory")
    return await _write_stream(destination, request.stream(), overwrite)


@app.post("/api/upload")
async def upload_multipart(
    token: WriteToken,
    file: UploadFile = File(...),
    path: str = Form(""),
    overwrite: bool = Form(False),
) -> dict:
    name = Path(file.filename or "upload.bin").name
    destination = _resolve(f"{path}/{name}" if path else name, must_exist=False)

    async def chunks():
        while True:
            block = await file.read(settings.chunk_bytes)
            if not block:
                break
            yield block

    return await _write_stream(destination, chunks(), overwrite)


@app.post("/api/mkdir")
def mkdir(body: PathBody, token: WriteToken) -> dict:
    target = _resolve(body.path, must_exist=False)
    target.mkdir(parents=True, exist_ok=True)
    return {"path": storage.relative(settings.root, target)}


@app.post("/api/move")
def move(body: MoveBody, token: WriteToken) -> dict:
    source = _resolve(body.src)
    destination = _resolve(body.dst, must_exist=False)
    if source == settings.root.resolve():
        raise HTTPException(status_code=400, detail="cannot move the share root")
    if destination.exists() and destination.is_dir():
        destination = destination / source.name
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(destination))
    return {"path": storage.relative(settings.root, destination)}


@app.post("/api/delete")
def delete(body: DeleteBody, token: WriteToken) -> dict:
    target = _resolve(body.path)
    if target == settings.root.resolve():
        raise HTTPException(status_code=400, detail="cannot delete the share root")
    if target.is_dir():
        if not body.recursive and any(target.iterdir()):
            raise HTTPException(status_code=400, detail="directory not empty")
        shutil.rmtree(target) if body.recursive else target.rmdir()
    else:
        target.unlink()
    return {"deleted": body.path}


@app.exception_handler(storage.PathError)
def path_error_handler(request: Request, exc: storage.PathError) -> JSONResponse:
    return JSONResponse(status_code=400, content={"detail": str(exc)})
