#!/usr/bin/env python3
"""Builds a bootfs image (K8b): Zircon's bootfs format, without a ZBI
container around it. The loader reads it as \\croi\\bootfs.img and userboot
finds programs in it.

    mkbootfs.py <out.img> <name>=<file> ...

Layout (zircon zbi-format bootfs.h): a 16-byte header (magic, dirsize, two
reserved words), then directory entries (name_len with the NUL, data_len,
data_off, the name, padded to 4 bytes), then each file at a page-aligned
offset from the start of the image, zero padded to a page.
"""

import struct
import sys

MAGIC = 0xA56D3FF9
PAGE = 4096
MAX_NAME = 256


def align(value, to):
    return (value + to - 1) & ~(to - 1)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    out, specs = argv[0], argv[1:]
    files = []
    for spec in specs:
        name, sep, path = spec.partition("=")
        if not sep or not name or name.startswith("/"):
            sys.exit(f"mkbootfs: bad entry {spec!r} (want name=file, name not starting with /)")
        encoded = name.encode() + b"\0"
        if len(encoded) > MAX_NAME:
            sys.exit(f"mkbootfs: name too long: {name}")
        with open(path, "rb") as f:
            files.append((encoded, f.read()))
    names = [n for n, _ in files]
    if len(set(names)) != len(names):
        sys.exit("mkbootfs: duplicate names")

    dirsize = sum(align(12 + len(n), 4) for n, _ in files)
    offset = align(16 + dirsize, PAGE)
    directory = bytearray()
    data = bytearray()
    for name, contents in files:
        directory += struct.pack("<III", len(name), len(contents), offset)
        directory += name + b"\0" * (align(12 + len(name), 4) - 12 - len(name))
        data += contents + b"\0" * (align(len(contents), PAGE) - len(contents))
        offset += align(len(contents), PAGE)
    image = struct.pack("<IIII", MAGIC, dirsize, 0, 0) + directory
    image += b"\0" * (align(len(image), PAGE) - len(image))
    with open(out, "wb") as f:
        f.write(image + data)


if __name__ == "__main__":
    main(sys.argv[1:])
