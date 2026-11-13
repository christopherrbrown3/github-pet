#!/usr/bin/env python3
"""Pack image-generated art. macOS sips supplies image resampling, never drawing.

Run from any directory: python3 docs/design/build_pack.py
Only assets/mascots/mona-pet-v1 is written. The source PNGs are never changed.
"""
from pathlib import Path
import json
import subprocess
import tempfile
from png_rgba import bounds, crop, read_png, sha256_png, write_png

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / 'assets/mascots/mona-pet-v1'
CANVAS, ANCHOR, FACE_WIDTH = 256, [128, 232], 112


def sha(path):
    return sha256_png(path)


def make_frame(sheet, number, destination):
    width, height, pixels = read_png(sheet)
    assert width == height and width % 2 == 0
    cell_size = width // 2
    cell = crop(pixels, width, (number % 2) * cell_size, (number // 2) * cell_size, cell_size, cell_size)
    silhouette = bounds(cell, cell_size, lambda r, g, b, a: a > 8)
    face = bounds(cell, cell_size, lambda r, g, b, a: a > 128 and r > 180 and g > 145 and b > 115 and r > g > b)
    assert min(silhouette[0], silhouette[1], cell_size - silhouette[2], cell_size - silhouette[3]) >= 16
    # Generated sheets contain stray alpha values <= 8 well outside the visible
    # contour. Remove only this near-invisible haze before canvas alignment.
    for i in range(0, len(cell), 4):
        if cell[i + 3] <= 8:
            cell[i:i + 4] = b'\0\0\0\0'
    size = round(cell_size * FACE_WIDTH / (face[2] - face[0]))
    with tempfile.TemporaryDirectory(dir=PACK, prefix='.pack-') as temp:
        original, scaled = Path(temp) / 'cell.png', Path(temp) / 'scaled.png'
        write_png(original, cell_size, cell_size, cell)
        subprocess.run(['sips', '--resampleHeightWidth', str(size), str(size), str(original), '--out', str(scaled)], check=True, capture_output=True)
        sw, sh, resized = read_png(scaled)
    # Center the cream face horizontally; put the lowest tentacle on the same
    # baseline. This corrects source-grid drift without redrawing the character.
    actual_scale = size / cell_size
    dx = ANCHOR[0] - round((face[0] + face[2]) / 2 * actual_scale)
    dy = ANCHOR[1] - round(silhouette[3] * actual_scale)
    output = bytearray(CANVAS * CANVAS * 4)
    for y in range(sh):
        for x in range(sw):
            source = (y * sw + x) * 4
            tx, ty = x + dx, y + dy
            if 0 <= tx < CANVAS and 0 <= ty < CANVAS:
                target = (ty * CANVAS + tx) * 4
                output[target:target + 4] = resized[source:source + 4]
            elif resized[source + 3] > 0:
                raise ValueError(f'Packing would crop nontransparent pixels: {sheet}, {number}')
    write_png(destination, CANVAS, CANVAS, output)
    return {'sourceCell': number, 'sourceFaceBounds': face, 'sourceAlphaBounds': silhouette,
            'scaledCellSize': size, 'translation': [dx, dy],
            'alphaBounds': bounds(output, CANVAS, lambda r, g, b, a: a > 8)}


def main():
    states, transforms, hashes, sheets = {}, {}, {}, {}
    definitions = {
        'idle': ([0, 1, 2, 3], [2000, 200, 200, 2000], True, 0),
        'attention': ([0, 1, 2, 3], [300, 400, 400, 800], False, 3),
        # Source cell 3 has generator-added motion ticks. It is preserved in
        # provenance, but excluded from the shipped runtime sequence.
        'urgent': ([0, 1, 2, 0], [300, 400, 400, 800], False, 0),
    }
    for state, (cells, durations, loop, fallback) in definitions.items():
        frames = []
        atlas = bytearray(CANVAS * 4 * CANVAS * 4)
        transforms[state] = []
        for index, cell in enumerate(cells):
            relative = f'frames/{state}-{index:02}.png'
            path = PACK / relative
            transforms[state].append(make_frame(PACK / 'sources' / f'{state}-sheet.png', cell, path))
            frames.append(relative)
            hashes[relative] = sha(path)
            _, _, pixels = read_png(path)
            for y in range(CANVAS):
                offset = (y * CANVAS * 4 + index * CANVAS) * 4
                atlas[offset:offset + CANVAS * 4] = pixels[y * CANVAS * 4:(y + 1) * CANVAS * 4]
        sheet = f'sheets/{state}.png'
        write_png(PACK / sheet, CANVAS * 4, CANVAS, atlas)
        sheets[state] = {'path': sheet, 'size': [1024, 256], 'rects': [[i * 256, 0, 256, 256] for i in range(4)], 'sha256': sha(PACK / sheet)}
        states[state] = {'frames': frames, 'durationMs': durations, 'loop': loop, 'staticFallback': frames[fallback]}
    manifest = {'schemaVersion': 1, 'id': 'mona-pet-v1', 'name': 'Mona-inspired Pet',
                'canvas': {'width': CANVAS, 'height': CANVAS}, 'anchor': ANCHOR,
                'states': states, 'frameSha256': hashes}
    (PACK / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    packing = {'canvas': [256, 256], 'anchor': ANCHOR, 'faceWidthTarget': FACE_WIDTH,
               'resampling': 'macOS sips; original generated artwork only', 'sourceAlphaCleanupThreshold': 8, 'transforms': transforms,
               'sheets': sheets, 'sourceSha256': {str(p.relative_to(PACK)): sha(p) for p in sorted((PACK / 'sources').glob('*.png'))}}
    (PACK / 'packing.json').write_text(json.dumps(packing, indent=2) + '\n')
    print(f'Packed {sum(len(s["frames"]) for s in states.values())} frames; manifest {sha(PACK / "manifest.json")}')


if __name__ == '__main__':
    main()
