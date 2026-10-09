#!/usr/bin/env python3
"""Check pixels of a binary PPM (P6) screendump.

Usage: check-pixels.py <file.ppm> x,y,r,g,b [x,y,r,g,b ...]
"""

import sys


def read_ppm(path):
    data = open(path, "rb").read()
    fields = []
    pos = 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    if fields[0] != b"P6" or int(fields[3]) != 255:
        sys.exit(f"{path}: not an 8-bit P6 PPM")
    width, height = int(fields[1]), int(fields[2])
    return width, height, data[pos + 1:]


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    width, height, pixels = read_ppm(argv[1])
    failed = False
    for spec in argv[2:]:
        x, y, r, g, b = (int(v) for v in spec.split(","))
        if not (0 <= x < width and 0 <= y < height):
            print(f"({x},{y}) is outside the {width}x{height} screen")
            failed = True
            continue
        at = (y * width + x) * 3
        actual = tuple(pixels[at:at + 3])
        if actual != (r, g, b):
            print(f"({x},{y}) is {actual}, expected {(r, g, b)}")
            failed = True
    print(f"{width}x{height}: {'FAILED' if failed else 'ok'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main(sys.argv)
