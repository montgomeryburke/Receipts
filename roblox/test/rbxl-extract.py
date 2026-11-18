#!/usr/bin/env python3
"""
Pull the Luau source back out of a binary .rbxl.

Rojo builds a place file from source and cannot do the reverse, so when a
place file comes back with edits inside it there is no supported way to get
them out. This reads the binary format directly.

Layout: a 32-byte header, then chunks. Each chunk is a 4-byte name, a
compressed length, an uncompressed length, 4 reserved bytes, and then the
payload -- LZ4 block compressed when the compressed length is non-zero.

  INST  declares a class: its id, its name, and how many instances
  PROP  one property for one class, with a value per instance IN THE SAME
        ORDER as that class's instances

So the Name array and the Source array of a given class line up by index,
which is all that is needed to pair a script with its code.
"""
import struct
import sys


def lz4_decompress(src: bytes, expected: int) -> bytes:
    """LZ4 block format. No stdlib support for it, so here it is."""
    out = bytearray()
    i = 0
    n = len(src)
    while i < n:
        token = src[i]
        i += 1

        literal = token >> 4
        if literal == 15:
            while True:
                add = src[i]
                i += 1
                literal += add
                if add != 255:
                    break
        out += src[i:i + literal]
        i += literal

        if i >= n:
            break

        offset = src[i] | (src[i + 1] << 8)
        i += 2

        match = token & 0x0F
        if match == 15:
            while True:
                add = src[i]
                i += 1
                match += add
                if add != 255:
                    break
        match += 4

        # Overlapping copies are legal and common, so this must be byte wise.
        start = len(out) - offset
        for k in range(match):
            out.append(out[start + k])

    if expected and len(out) != expected:
        raise ValueError(f"lz4: got {len(out)} bytes, expected {expected}")
    return bytes(out)


def chunks(data: bytes):
    offset = 32  # past the header
    while offset < len(data):
        name = data[offset:offset + 4]
        compressed, uncompressed = struct.unpack_from("<II", data, offset + 4)
        offset += 16
        payload = data[offset:offset + (compressed if compressed else uncompressed)]
        offset += len(payload)
        if compressed:
            payload = lz4_decompress(payload, uncompressed)
        yield name.rstrip(b"\0").decode("ascii", "replace"), payload
        if name.startswith(b"END"):
            break


def read_string(buf: bytes, at: int):
    (length,) = struct.unpack_from("<I", buf, at)
    at += 4
    return buf[at:at + length], at + length


def untransform_i32(words):
    """Roblox stores integers byte-interleaved and zigzag encoded."""
    return [(w >> 1) ^ (-(w & 1)) for w in words]


def read_interleaved_u32(buf: bytes, at: int, count: int):
    raw = buf[at:at + count * 4]
    values = []
    for index in range(count):
        values.append(
            (raw[index] << 24)
            | (raw[count + index] << 16)
            | (raw[2 * count + index] << 8)
            | raw[3 * count + index]
        )
    return values, at + count * 4


def parse(path):
    data = open(path, "rb").read()

    classes = {}   # class id -> {"name": str, "count": int}
    props = {}     # (class id, prop name) -> list of values

    for name, payload in chunks(data):
        if name == "INST":
            (class_id,) = struct.unpack_from("<I", payload, 0)
            at = 4
            class_name, at = read_string(payload, at)
            at += 1  # object-format flag
            (count,) = struct.unpack_from("<I", payload, at)
            at += 4
            classes[class_id] = {
                "name": class_name.decode("utf-8", "replace"),
                "count": count,
            }

        elif name == "PROP":
            (class_id,) = struct.unpack_from("<I", payload, 0)
            at = 4
            prop_name, at = read_string(payload, at)
            prop_name = prop_name.decode("utf-8", "replace")
            if at >= len(payload):
                continue
            type_id = payload[at]
            at += 1

            # 0x01 String covers Name and Source, which is all we need.
            if type_id != 0x01:
                continue
            count = classes.get(class_id, {}).get("count", 0)
            values = []
            for _ in range(count):
                raw, at = read_string(payload, at)
                values.append(raw.decode("utf-8", "replace"))
            props[(class_id, prop_name)] = values

    scripts = {}
    for class_id, info in classes.items():
        if info["name"] not in ("Script", "LocalScript", "ModuleScript"):
            continue
        names = props.get((class_id, "Name"), [])
        sources = props.get((class_id, "Source"), [])
        for index, source in enumerate(sources):
            label = names[index] if index < len(names) else f"{info['name']}_{index}"
            scripts[f"{info['name']}:{label}"] = source

    return classes, scripts


if __name__ == "__main__":
    classes, scripts = parse(sys.argv[1])
    print(f"classes: {len(classes)}", file=sys.stderr)
    print(f"scripts: {len(scripts)}", file=sys.stderr)
    for key, source in sorted(scripts.items()):
        print(f"{key}\t{len(source)}")
