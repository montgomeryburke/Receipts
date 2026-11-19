#!/usr/bin/env python3
"""
Write every script inside a binary .rbxl out as a file.

    python3 test/rbxl-dump.py NuclearMudArena.rbxl /tmp/placesrc

Which is how you review a place file somebody hands back: Rojo builds one
from source and cannot do the reverse, so without this there is no way to
see what changed inside it.

The import below used to be `from rbxl import parse`, which could never have
worked -- the module it wants is rbxl-extract.py, and a hyphen is not legal
in a Python module name, so the statement raised ModuleNotFoundError every
time. Nothing caught it because nothing in the suite runs this file; it is a
tool for a person, and it had been broken for as long as it had existed.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "rbxl_extract", os.path.join(HERE, "rbxl-extract.py")
)
_rbxl = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_rbxl)
parse = _rbxl.parse


# A ModuleScript keeps its own name; the two entry points are named for what
# Rojo calls them, so a dump drops straight next to the real source.
EXTENSIONS = {"Script": "server.luau", "LocalScript": "client.luau"}


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <place.rbxl> <output directory>", file=sys.stderr)
        return 2

    place, out = sys.argv[1], sys.argv[2]
    _, scripts = parse(place)
    os.makedirs(out, exist_ok=True)

    for key, source in sorted(scripts.items()):
        cls, name = key.split(":", 1)
        extension = EXTENSIONS.get(cls, "luau")
        with open(os.path.join(out, f"{name}.{extension}"), "w") as handle:
            handle.write(source)

    print(f"wrote {len(scripts)} files to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
