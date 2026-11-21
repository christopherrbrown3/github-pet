#!/usr/bin/env python3
"""Lossless PNG re-encoder for README images (Python standard library only).

    python3 -I scripts/png-optimize.py file.png [...]

Decodes 8-bit RGBA/RGB, non-interlaced PNGs, drops the alpha channel when every pixel is opaque,
picks each row's filter by the minimum-sum-of-absolute-differences heuristic and recompresses at
zlib level 9. Pixels are unchanged (checked by decoding the result). Keeps pHYs (the @2x DPI) and
sRGB/iCCP/gAMA chunks; drops text and time chunks. A file is only replaced when it gets smaller.
"""
import struct
import sys
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
KEEP = {b"pHYs", b"sRGB", b"iCCP", b"gAMA", b"cHRM"}


def chunks(data):
    position = len(SIGNATURE)
    while position < len(data):
        (length,) = struct.unpack(">I", data[position:position + 4])
        kind = data[position + 4:position + 8]
        yield kind, data[position + 8:position + 8 + length]
        position += 12 + length


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    return a if pa <= pb and pa <= pc else (b if pb <= pc else c)


def unfilter(raw, width, height, bpp):
    stride = width * bpp
    rows, previous, position = [], bytearray(stride), 0
    for _ in range(height):
        kind, line = raw[position], bytearray(raw[position + 1:position + 1 + stride])
        position += 1 + stride
        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up, corner = previous[i], (previous[i - bpp] if i >= bpp else 0)
            if kind == 1: line[i] = (line[i] + left) & 255
            elif kind == 2: line[i] = (line[i] + up) & 255
            elif kind == 3: line[i] = (line[i] + ((left + up) >> 1)) & 255
            elif kind == 4: line[i] = (line[i] + paeth(left, up, corner)) & 255
        rows.append(bytes(line))
        previous = line
    return rows


def filtered(rows, bpp):
    out, previous = bytearray(), bytes(len(rows[0]))
    for line in rows:
        best, best_score = None, None
        for kind in range(5):
            candidate = bytearray(len(line))
            for i, value in enumerate(line):
                left = line[i - bpp] if i >= bpp else 0
                up, corner = previous[i], (previous[i - bpp] if i >= bpp else 0)
                predictor = (0, left, up, (left + up) >> 1, paeth(left, up, corner))[kind]
                candidate[i] = (value - predictor) & 255
            score = sum(v if v < 128 else 256 - v for v in candidate)
            if best_score is None or score < best_score:
                best, best_score = bytes([kind]) + bytes(candidate), score
        out += best
        previous = line
    return bytes(out)


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def decode(data):
    header, idat, extra = None, b"", []
    for kind, body in chunks(data):
        if kind == b"IHDR": header = body
        elif kind == b"IDAT": idat += body
        elif kind in KEEP: extra.append((kind, body))
    width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", header)
    if depth != 8 or colour not in (2, 6) or interlace:
        raise ValueError("only 8-bit RGB/RGBA non-interlaced PNGs")
    bpp = 4 if colour == 6 else 3
    return width, height, bpp, unfilter(zlib.decompress(idat), width, height, bpp), extra


def pixels(width, rows, bpp):
    """RGBA bytes for comparison."""
    if bpp == 4:
        return b"".join(rows)
    return b"".join(bytes(b for i in range(width) for b in row[i * 3:i * 3 + 3] + b"\xff") for row in rows)


def optimize(path):
    original = open(path, "rb").read()
    width, height, bpp, rows, extra = decode(original)
    if bpp == 4 and all(row[3::4] == b"\xff" * width for row in rows):
        rows = [bytes(b for i in range(width) for b in row[i * 4:i * 4 + 3]) for row in rows]
        bpp = 3
    header = struct.pack(">IIBBBBB", width, height, 8, 6 if bpp == 4 else 2, 0, 0, 0)
    body = SIGNATURE + chunk(b"IHDR", header) + b"".join(chunk(k, v) for k, v in extra)
    body += chunk(b"IDAT", zlib.compress(filtered(rows, bpp), 9)) + chunk(b"IEND", b"")
    before = decode(original)
    after = decode(body)
    if pixels(width, before[3], before[2]) != pixels(width, after[3], after[2]):
        raise ValueError("re-encoded pixels differ")
    if len(body) < len(original):
        open(path, "wb").write(body)
    print(f"{path}: {len(original)} -> {min(len(body), len(original))} bytes")


if __name__ == "__main__":
    for name in sys.argv[1:]:
        optimize(name)
