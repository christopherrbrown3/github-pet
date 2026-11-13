"""Small RGBA8 PNG reader/writer for asset packing checks; no drawing routines."""
import hashlib
import struct
import zlib

# Covers the 1254×1254 generated sheets and the 1024×256 packed sheets while
# bounding untrusted input, decompressed output and per-row allocations.
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_EDGE = 2048
MAX_PIXELS = 2048 * 2048


def sha256_png(path):
    """Hash PNG inputs without an unbounded read, including after file swaps."""
    digest, total = hashlib.sha256(), 0
    with path.open('rb') as stream:
        while True:
            chunk = stream.read(min(1024 * 1024, MAX_FILE_BYTES + 1 - total))
            if not chunk:
                return digest.hexdigest()
            total += len(chunk)
            if total > MAX_FILE_BYTES:
                raise ValueError(f'PNG file exceeds size limit: {path}')
            digest.update(chunk)


def read_png(path):
    blob = bytearray()
    with path.open('rb') as stream:
        while True:
            chunk = stream.read(min(64 * 1024, MAX_FILE_BYTES + 1 - len(blob)))
            if not chunk:
                break
            blob.extend(chunk)
            if len(blob) > MAX_FILE_BYTES:
                raise ValueError(f'PNG file exceeds size limit: {path}')
    if blob[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    pos, compressed = 8, bytearray()
    header_seen = idat_seen = idat_closed = end_seen = False
    while pos < len(blob):
        if len(blob) - pos < 12:
            raise ValueError(f'Truncated PNG chunk: {path}')
        size = struct.unpack('>I', blob[pos:pos + 4])[0]
        if size > len(blob) - pos - 12:
            raise ValueError(f'Truncated PNG chunk: {path}')
        kind = blob[pos + 4:pos + 8]
        chunk = blob[pos + 8:pos + 8 + size]
        crc = struct.unpack('>I', blob[pos + 8 + size:pos + 12 + size])[0]
        if zlib.crc32(kind + chunk) & 0xffffffff != crc:
            raise ValueError(f'Bad PNG CRC: {path}')
        if kind == b'IHDR':
            if header_seen or pos != 8 or size != 13:
                raise ValueError(f'Invalid PNG header: {path}')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', chunk)
            if not (0 < width <= MAX_EDGE and 0 < height <= MAX_EDGE and width * height <= MAX_PIXELS):
                raise ValueError(f'PNG dimensions exceed supported limits: {path}')
            if (depth, color, compression, filtering, interlace) != (8, 6, 0, 0, 0):
                raise ValueError(f'Expected noninterlaced RGBA8: {path}')
            header_seen = True
        elif kind == b'IDAT':
            if not header_seen or idat_closed:
                raise ValueError(f'Invalid PNG data order: {path}')
            idat_seen = True
            compressed.extend(chunk)
        elif kind == b'IEND':
            if not header_seen or not idat_seen or size != 0 or pos + 12 != len(blob):
                raise ValueError(f'Invalid PNG end: {path}')
            end_seen = True
        else:
            if not header_seen:
                raise ValueError(f'PNG header must be first: {path}')
            if idat_seen:
                idat_closed = True
        pos += size + 12
        if end_seen:
            break
    if not end_seen:
        raise ValueError(f'Missing PNG end: {path}')
    stride = width * 4
    expected = height * (stride + 1)
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(compressed, expected + 1)
    except zlib.error as exc:
        raise ValueError(f'Invalid PNG compressed data: {path}') from exc
    if len(raw) != expected or not decoder.eof or decoder.unconsumed_tail or decoder.unused_data:
        raise ValueError(f'Unexpected scanline length: {path}')
    offset, previous, pixels = 0, bytearray(stride), bytearray()
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
    min_x, min_y, max_x, max_y = width, len(pixels) // (width * 4), -1, -1
    for i in range(0, len(pixels), 4):
        if predicate(*pixels[i:i + 4]):
            x, y = (i // 4) % width, (i // 4) // width
            min_x, min_y = min(min_x, x), min(min_y, y)
            max_x, max_y = max(max_x, x), max(max_y, y)
    if max_x < 0:
        raise ValueError('Empty selection')
    return [min_x, min_y, max_x + 1, max_y + 1]
