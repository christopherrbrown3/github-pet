#!/usr/bin/env python3
"""Rebuild Little Chris from the supplied pose sheet using Python and macOS sips.

This writes the v1 manifest: run build_pack_v2.py afterwards for the schema v2 clips (#138).
"""
import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from png_rgba import bounds, crop, read_png, sha256_png, write_png


PACK = Path(__file__).resolve().parents[2] / 'assets/mascots/little-chris-v1'
SOURCE = PACK / 'source/little-chris-poses.png'
SOURCE_SHA256 = 'a87cd707e04e8f06ee110dab68d6d176e46ba459163ed317ccab33c32d1128b1'
CELL = 418
SCALED_CELL = 236  # Common 375–376 px source height becomes about 212 px.
CANVAS = 256
ANCHOR = [128, 232]
HAZE_ALPHA = 8
STATES = {
    'idle': ([2000, 125, 125], 'frames/idle-00.png'),
    'attention': ([350, 600, 350], 'frames/idle-00.png'),
    'urgent': ([300, 900, 500], 'frames/urgent-02.png'),
}


def pack_cell(cell, working):
    x0, y0, x1, y1 = bounds(cell, CELL, lambda r, g, b, a: a > HAZE_ALPHA)
    if min(x0, y0, CELL - x1, CELL - y1) < 8:
        raise ValueError('Pose too close to a source cell edge')
    # Drop the faint matte outside the silhouette while retaining its visible edge.
    for i in range(0, len(cell), 4):
        if cell[i + 3] <= HAZE_ALPHA:
            cell[i:i + 4] = b'\0' * 4

    original, scaled = working / 'cell.png', working / 'scaled.png'
    write_png(original, CELL, CELL, cell)
    subprocess.run(
        ['sips', '--resampleHeightWidth', str(SCALED_CELL), str(SCALED_CELL),
         str(original), '--out', str(scaled)],
        check=True, capture_output=True,
    )
    width, height, resized = read_png(scaled)
    left, top, right, bottom = bounds(resized, width, lambda r, g, b, a: a > 0)
    # Use the bottom eight solid shoe rows to center the stance. Hands and
    # head tilt can change the sprite's overall silhouette center.
    _, _, _, solid_bottom = bounds(resized, width, lambda r, g, b, a: a > 127)
    soles = crop(resized, width, 0, solid_bottom - 8, width, 8)
    shoe_left, _, shoe_right, _ = bounds(soles, width, lambda r, g, b, a: a > 127)
    dx = ANCHOR[0] - (shoe_left + shoe_right + 1) // 2
    dy = ANCHOR[1] - bottom
    if min(left + dx, top + dy, CANVAS - right - dx, CANVAS - bottom - dy) < 8:
        raise ValueError('Pose would enter the required transparent canvas padding')

    output = bytearray(CANVAS * CANVAS * 4)
    for y in range(top, bottom):
        start, end = (y * width + left) * 4, (y * width + right) * 4
        offset = ((y + dy) * CANVAS + left + dx) * 4
        output[offset:offset + end - start] = resized[start:end]
    return output


def main():
    if sha256_png(SOURCE) != SOURCE_SHA256:
        raise ValueError('Source sheet SHA-256 mismatch')
    width, height, pixels = read_png(SOURCE)
    if (width, height) != (3 * CELL, 3 * CELL):
        raise ValueError('Expected a 3 × 3 grid of 418 px cells')

    states, hashes = {}, {}
    with TemporaryDirectory(prefix='.little-chris-', dir=PACK) as temp:
        for row, (state, (durations, fallback)) in enumerate(STATES.items()):
            frames = []
            for column in range(3):
                cell = crop(pixels, width, column * CELL, row * CELL, CELL, CELL)
                output = pack_cell(cell, Path(temp))
                path = f'frames/{state}-{column:02}.png'
                write_png(PACK / path, CANVAS, CANVAS, output)
                frames.append(path)
                hashes[path] = sha256_png(PACK / path)
            states[state] = {
                'frames': frames, 'durationMs': durations,
                'loop': state == 'idle', 'staticFallback': fallback,
            }

    manifest = {
        'schemaVersion': 1, 'id': 'little-chris-v1', 'name': 'Little Chris',
        'canvas': {'width': CANVAS, 'height': CANVAS}, 'anchor': ANCHOR,
        'states': states, 'frameSha256': hashes,
    }
    (PACK / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
