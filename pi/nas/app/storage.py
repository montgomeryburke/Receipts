"""Path resolution and filesystem helpers.

The single most important function here is :func:`resolve`. Every request-supplied
path goes through it, and nothing else in the app is allowed to build a path by
concatenating strings.
"""
from __future__ import annotations

import os
import shutil
import stat
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


class PathError(ValueError):
    """Raised when a client-supplied path is unusable or escapes the root."""


@dataclass
class Entry:
    name: str
    path: str
    is_dir: bool
    size: int
    modified: float

    def as_dict(self) -> dict:
        return {
            "name": self.name,
            "path": self.path,
            "is_dir": self.is_dir,
            "size": self.size,
            "modified": self.modified,
        }


def _clean_parts(raw: str) -> list[str]:
    """Split a client path into safe components.

    Rejects absolute paths, ``..`` segments, NUL bytes, and Windows drive/UNC
    forms. Backslashes are treated as separators so a Windows-style path cannot
    smuggle a segment past the ``..`` check.
    """
    if "\x00" in raw:
        raise PathError("path contains a NUL byte")
    normalised = raw.replace("\\", "/").strip()
    if normalised.startswith("/"):
        normalised = normalised.lstrip("/")
    parts: list[str] = []
    for part in PurePosixPath(normalised).parts:
        if part in ("", "."):
            continue
        if part == "..":
            raise PathError("path may not contain '..'")
        if ":" in part:
            raise PathError("path may not contain ':'")
        parts.append(part)
    return parts


def resolve(root: Path, raw: str, *, must_exist: bool = True) -> Path:
    """Turn a client path into an absolute path guaranteed to sit under *root*.

    Symlinks are resolved before the containment check, so a symlink inside the
    share that points outside it is rejected rather than followed.
    """
    root_real = root.resolve()
    candidate = root_real.joinpath(*_clean_parts(raw))

    # Resolve as far as the path exists; strict=False lets us validate the
    # destination of a not-yet-created file without failing outright.
    resolved = candidate.resolve()

    if resolved != root_real and root_real not in resolved.parents:
        raise PathError("path escapes the share root")
    if must_exist and not resolved.exists():
        raise FileNotFoundError(raw)
    return resolved


def relative(root: Path, target: Path) -> str:
    """Path as the client sees it: POSIX, root-relative, no leading slash."""
    root_real = root.resolve()
    if target == root_real:
        return ""
    return target.resolve().relative_to(root_real).as_posix()


def list_dir(root: Path, directory: Path, *, show_hidden: bool = False) -> list[Entry]:
    entries: list[Entry] = []
    with os.scandir(directory) as scanner:
        for item in scanner:
            if not show_hidden and item.name.startswith("."):
                continue
            try:
                info = item.stat()
            except OSError:
                # Broken symlink or a file that vanished mid-scan; skip it
                # rather than failing the whole listing.
                continue
            if not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                continue
            entries.append(
                Entry(
                    name=item.name,
                    path=relative(root, Path(item.path)),
                    is_dir=stat.S_ISDIR(info.st_mode),
                    size=info.st_size,
                    modified=info.st_mtime,
                )
            )
    entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
    return entries


def disk_usage(path: Path) -> dict:
    total, used, free = shutil.disk_usage(path)
    return {"total": total, "used": used, "free": free}


def unique_destination(target: Path) -> Path:
    """If *target* exists, return ``name (2).ext``-style path that does not."""
    if not target.exists():
        return target
    stem, suffix = target.stem, target.suffix
    for counter in range(2, 1000):
        candidate = target.with_name(f"{stem} ({counter}){suffix}")
        if not candidate.exists():
            return candidate
    raise PathError("could not find a free filename")
