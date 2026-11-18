#!/usr/bin/env python3
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rbxl import parse

_, scripts = parse(sys.argv[1])
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
for key, source in scripts.items():
    cls, name = key.split(":", 1)
    ext = {"Script": "server.luau", "LocalScript": "client.luau"}.get(cls, "luau")
    with open(os.path.join(out, f"{name}.{ext}"), "w") as handle:
        handle.write(source)
print(f"wrote {len(scripts)} files to {out}")
