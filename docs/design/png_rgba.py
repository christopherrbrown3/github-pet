"""Small RGBA8 PNG reader/writer for asset packing checks; no drawing routines."""
import struct
import zlib


def read_png(path):
    blob = path.read_bytes()
    if blob[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    pos, compressed = 8, bytearray()
    while pos < len(blob):
        size = struct.unpack('>I', blob[pos:pos + 4])[0]
        kind = blob[pos + 4:pos + 8]
        chunk = blob[pos + 8:pos + 8 + size]
        crc = struct.unpack('>I', blob[pos + 8 + size:pos + 12 + size])[0]
        if zlib.crc32(kind + chunk) & 0xffffffff != crc:
            raise ValueError(f'Bad PNG CRC: {path}')
        if kind == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', chunk)
        elif kind == b'IDAT':
            compressed.extend(chunk)
        pos += size + 12
    if (depth, color, interlace) != (8, 6, 0):
        raise ValueError(f'Expected noninterlaced RGBA8: {path}')
    raw = zlib.decompress(compressed)
    stride, offset, previous, pixels = width * 4, 0, bytearray(width * 4), bytearray()
    if len(raw) != height * (stride + 1):
        raise ValueError(f'Unexpected scanline length: {path}')
    for _ in range(height):
        method = raw[offset]
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        offset += stride + 1
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            above = previous[x]
            upper_left = previous[x - 4] if x >= 4 else 0
            if method == 0:
                predictor = 0
            elif method == 1:
                predictor = left
            elif method == 2:
                predictor = above
            elif method == 3:
                predictor = (left + above) // 2
            elif method == 4:
                p = left + above - upper_left
                a, b, c = abs(p - left), abs(p - above), abs(p - upper_left)
                predictor = left if a <= b and a <= c else above if b <= c else upper_left
            else:
                raise ValueError(f'Bad PNG filter: {path}')
            row[x] = (row[x] + predictor) & 255
        pixels.extend(row)
        previous = row
    return width, height, pixels


def write_png(path, width, height, pixels):
    assert len(pixels) == width * height * 4
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    rows = b''.join(b'\0' + pixels[y * width * 4:(y + 1) * width * 4] for y in range(height))
    blob = b'\x89PNG\r\n\x1a\n'
    blob += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
    blob += chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)


def crop(pixels, width, x, y, w, h):
    return bytearray(b''.join(pixels[((y + row) * width + x) * 4:((y + row) * width + x + w) * 4] for row in range(h)))


def bounds(pixels, width, predicate):
    xs, ys = [], []
    for i in range(0, len(pixels), 4):
        if predicate(*pixels[i:i + 4]):
            xs.append((i // 4) % width)
            ys.append((i // 4) // width)
    if not xs:
        raise ValueError('Empty selection')
    return [min(xs), min(ys), max(xs) + 1, max(ys) + 1]
