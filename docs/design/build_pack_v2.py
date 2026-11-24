#!/usr/bin/env python3
"""Pack the #138 schema v2 art (animation-v1.md sections 4 and 5). macOS sips resamples; nothing is drawn.

Run after the v1 builders, from any directory: python3 docs/design/build_pack_v2.py
Writes the v2 runtime frames, the hat accessory, the v2 manifest and the "v2" section of each pack's
packing.json, plus the shared FX sprites. The generated sources and the v1 state frames are never changed.

Every runtime frame comes from exactly one generated cell (CELLS maps them; the map was made by looking
at each cell, and cells left empty or superseded are listed in EXCLUDED). Per frame the builder:
  1. drops alpha <= 8 haze from the cell (and again after resampling),
  2. measures the face (Mona's cream mask, Little Chris's skin) as the largest connected face-colour
     region, and resamples the whole cell with sips so the face width matches idle-00's,
  3. aligns the face centre to idle-00's face centre and the lowest visible pixel to y 232.
Points are measured from the same masks: `head` is the face top minus idle-00's face-top-to-skull
offset, `nozzle` the far tip of the steel nozzle, `hand` the raised limb. The hat accessory is the
props-reference helmet cut out and resampled; it is composited only for incident-start-05 (idle-00 with
the hat). Replacing generated helmets with it is evaluated, never painted (see HELMET_REPLACEMENT).
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile
from png_rgba import bounds, crop, read_png, sha256_png, write_png

ROOT = Path(__file__).resolve().parents[2]
MASCOTS = ROOT / 'assets/mascots'
CANVAS, ANCHOR, HAZE_ALPHA = 256, [128, 232], 8
SHEET, GRID = 1254, 2
CELL = SHEET // GRID
# Generated art sometimes crosses the grid line (hair tips into the cell above). Each cell is read
# with this padding and keeps only the connected regions whose centre lies inside it.
PAD = 48
# Replace each generated helmet with the one cut-out helmet only when the cut-out covers every
# generated helmet pixel in every helmet-on frame. The evaluation is recorded either way.
HELMET_REPLACEMENT = 'evaluate'
HELMET_ON = ['incident-start-03', 'incident-start-04', 'incident-end-00', 'incident-end-01',
             'incident-end-02', 'incident-end-03', 'incident-end-04']

# frame -> (sheet stem under sources/, cell index in reading order on the 2 x 2 grid)
CELLS = {
    'incident-start-00': ('incident-start-a', 0), 'incident-start-01': ('incident-start-a', 1),
    'incident-start-02': ('incident-start-a', 2), 'incident-start-03': ('incident-start-a', 3),
    'incident-start-04': ('incident-start-b', 0),
    'incident-end-00': ('incident-end-a', 0), 'incident-end-01': ('incident-end-a', 1),
    'incident-end-02': ('incident-end-a', 2), 'incident-end-03': ('incident-end-a', 3),
    'incident-end-04': ('incident-end-b', 0), 'incident-end-05': ('incident-end-b', 1),
    'new-item-00': ('new-item', 0), 'new-item-01': ('new-item', 1), 'new-item-02': ('new-item', 2),
    'new-item-03': ('new-item', 3), 'new-item-04': ('new-item-b', 0),
    'item-cleared-00': ('cleared-poke', 0), 'item-cleared-01': ('cleared-poke', 1),
    'item-cleared-02': ('cleared-poke', 2), 'poke-00': ('cleared-poke', 3), 'poke-01': ('dizzy-poke', 3),
    'inbox-zero-00': ('inbox-zero', 0), 'inbox-zero-01': ('inbox-zero', 1), 'inbox-zero-02': ('inbox-zero', 2),
    'inbox-zero-03': ('inbox-zero', 3), 'inbox-zero-04': ('inbox-zero-b', 0),
    'drag-00': ('drag-drop', 0), 'drag-01': ('drag-drop', 1), 'drop-00': ('drag-drop', 2), 'drop-01': ('drag-drop', 3),
    'dizzy-00': ('dizzy-poke', 0), 'dizzy-01': ('dizzy-poke', 1), 'dizzy-02': ('dizzy-b', 0), 'dizzy-03': ('dizzy-b', 1),
    'idle-look-00': ('ambient-a', 0), 'idle-look-01': ('ambient-a', 1), 'idle-look-02': ('ambient-a', 2),
    'idle-stretch-00': ('ambient-a', 3), 'idle-stretch-01': ('ambient-b', 0), 'idle-stretch-02': ('ambient-b', 1),
    'idle-stretch-03': ('ambient-b', 2), 'idle-fidget-00': ('ambient-b', 3),
    'idle-fidget-01': ('ambient-c', 0), 'idle-fidget-02': ('ambient-c', 1),
    'doze-00': ('ambient-c', 2), 'doze-01': ('ambient-c', 3),
}
EXCLUDED = {
    'dizzy-poke cell 2': 'extra opposite-lean alternate; dizzy-02 comes from dizzy-b cell 0',
    'B sheets cells 1-3 (incident-end-b: 2-3)': 'left empty by generation',
}

# Section 3 timings. Clip frames may repeat and reuse idle-00.
HELD = {'drag': (['drag-00', 'drag-01'], [400, 400]), 'doze': (['doze-00', 'doze-01'], [1200, 1200])}
CLIPS = {
    'incident-start': (['incident-start-00', 'incident-start-01', 'incident-start-02', 'incident-start-03',
                        'incident-start-04', 'incident-start-05'], [250, 300, 300, 250, 500, 300], 'hide'),
    'incident-end': (['incident-end-00', 'incident-end-01', 'incident-end-02', 'incident-end-03', 'incident-end-02',
                      'incident-end-04', 'incident-end-05', 'idle-00'], [250, 250, 300, 300, 300, 300, 700, 300], 'hide'),
    'new-item': (['new-item-00', 'new-item-01', 'new-item-02', 'new-item-03', 'new-item-04'], [200, 200, 350, 350, 800], None),
    'item-cleared': (['item-cleared-00', 'item-cleared-01', 'item-cleared-02', 'idle-00'], [200, 300, 400, 300], None),
    'inbox-zero': (['inbox-zero-00', 'inbox-zero-01', 'inbox-zero-02', 'inbox-zero-01', 'inbox-zero-03', 'inbox-zero-04'],
                   [250, 300, 300, 300, 450, 400], None),
    'drop': (['drop-00', 'drop-01'], [200, 250], None),
    'poke': (['poke-00', 'poke-01', 'idle-00'], [250, 300, 200], None),
    'dizzy': (['dizzy-00', 'dizzy-01', 'dizzy-02', 'dizzy-01', 'dizzy-03'], [300, 300, 300, 300, 400], None),
    'idle-look': (['idle-look-00', 'idle-look-01', 'idle-look-02', 'idle-00'], [500, 500, 600, 400], None),
    'idle-stretch': (['idle-stretch-00', 'idle-stretch-01', 'idle-stretch-02', 'idle-stretch-03', 'idle-00'],
                     [400, 600, 500, 400, 500], None),
    'idle-fidget': (['idle-fidget-00', 'idle-fidget-01', 'idle-fidget-02', 'idle-00'], [400, 700, 400, 300], None),
}


def mona_face(r, g, b, a):
    return a > 128 and r > 180 and g > 145 and b > 115 and r > g > b


def skin_face(r, g, b, a):
    # Warm skin, not the cream helmet shield or envelope (green too close to red) nor the tan trousers.
    return a > 128 and r >= 200 and 0.6 * r <= g <= 0.86 * r and 70 <= b <= 175 and r - b >= 50


SKINS = {
    'mona-pet-v1': {'face': mona_face, 'brim': 100, 'union': (47, 217, 20),
                    'idleSource': ('sources/idle-sheet.png', 2, 0, 256 / 627)},
    'little-chris-v1': {'face': skin_face, 'brim': 90, 'union': (62, 205, 20),
                        'idleSource': ('source/little-chris-poses.png', 3, 0, 236 / 418)},
}


def red(r, g, b, a):
    return a > 128 and r >= 110 and r >= 1.6 * g and r >= 1.6 * b


def steel(r, g, b, a):
    return a > 128 and 120 <= min(r, g, b) and max(r, g, b) - min(r, g, b) <= 28 and max(r, g, b) <= 235


def components(pixels, width, height, predicate, eight=False):
    """Connected regions of predicate pixels: area, [x0, y0, x1, y1) and the pixel indices."""
    mask = bytearray(width * height)
    for i in range(width * height):
        if predicate(*pixels[i * 4:i * 4 + 4]):
            mask[i] = 1
    steps = [(-1, 0), (1, 0), (0, -1), (0, 1)] + ([(-1, -1), (1, -1), (-1, 1), (1, 1)] if eight else [])
    regions = []
    for start in range(width * height):
        if mask[start] != 1:
            continue
        mask[start] = 2
        stack, members = [start], []
        while stack:
            i = stack.pop()
            members.append(i)
            x, y = i % width, i // width
            for sx, sy in steps:
                nx, ny = x + sx, y + sy
                if 0 <= nx < width and 0 <= ny < height and mask[ny * width + nx] == 1:
                    mask[ny * width + nx] = 2
                    stack.append(ny * width + nx)
        xs = [i % width for i in members]
        ys = [i // width for i in members]
        regions.append({'area': len(members), 'box': [min(xs), min(ys), max(xs) + 1, max(ys) + 1], 'members': members})
    return sorted(regions, key=lambda region: -region['area'])


def clear_haze(pixels):
    dropped = 0
    for i in range(3, len(pixels), 4):
        if 0 < pixels[i] <= HAZE_ALPHA:
            pixels[i - 3:i + 1] = b'\0\0\0\0'
            dropped += 1
    return dropped


def face_box(pixels, width, predicate):
    regions = components(pixels, width, len(pixels) // 4 // width, predicate)
    if not regions:
        raise ValueError('No face region')
    return regions[0]['box']


def resample(pixels, width, height, out_w, out_h, work):
    source, scaled = work / 'in.png', work / 'out.png'
    write_png(source, width, height, pixels)
    subprocess.run(['sips', '--resampleHeightWidth', str(out_h), str(out_w), str(source), '--out', str(scaled)],
                   check=True, capture_output=True)
    w, h, out = read_png(scaled)
    assert (w, h) == (out_w, out_h)
    return out


def place(pixels, width, height, dx, dy, label):
    output = bytearray(CANVAS * CANVAS * 4)
    for y in range(height):
        for x in range(width):
            s = (y * width + x) * 4
            if pixels[s + 3] == 0:
                continue
            tx, ty = x + dx, y + dy
            if not (0 <= tx < CANVAS and 0 <= ty < CANVAS):
                raise ValueError(f'Packing would crop nontransparent pixels: {label}')
            t = (ty * CANVAS + tx) * 4
            output[t:t + 4] = pixels[s:s + 4]
    return output


def over(base, overlay, dx=0, dy=0):
    """Source-over composite of a 256 x 256 overlay translated by (dx, dy). Pixels are only blended."""
    output = bytearray(base)
    for y in range(CANVAS):
        for x in range(CANVAS):
            sx, sy = x - dx, y - dy
            if not (0 <= sx < CANVAS and 0 <= sy < CANVAS):
                continue
            s = (sy * CANVAS + sx) * 4
            alpha = overlay[s + 3]
            if alpha == 0:
                continue
            t = (y * CANVAS + x) * 4
            below = output[t + 3] * (255 - alpha) / 255
            out_alpha = alpha + below
            for c in range(3):
                output[t + c] = round((overlay[s + c] * alpha + output[t + c] * below) / out_alpha)
            output[t + 3] = round(out_alpha)
    return output


def fringe(pixels, width):
    """Saturated red pixels at partial alpha that are not the antialiased edge of opaque red art."""
    height = len(pixels) // 4 // width
    solid = bytearray(width * height)
    for i in range(width * height):
        r, g, b, a = pixels[i * 4:i * 4 + 4]
        if a >= 200 and r >= 2 * g and r >= 2 * b:
            solid[i] = 1
    count = 0
    for i in range(width * height):
        r, g, b, a = pixels[i * 4:i * 4 + 4]
        if 0 < a < 128 and r >= 60 and r >= 2 * g and r >= 2 * b:
            x, y = i % width, i // width
            near = any(solid[ny * width + nx] for ny in range(max(0, y - 3), min(height, y + 4))
                       for nx in range(max(0, x - 3), min(width, x + 4)))
            if not near:
                count += 1
    return count


def alpha_box(pixels, width=CANVAS):
    return bounds(pixels, width, lambda r, g, b, a: a > 0)


class Skin:
    def __init__(self, pack_id, config, work):
        self.id, self.config, self.work = pack_id, config, work
        self.pack = MASCOTS / pack_id
        self.sheets = {}
        relative, grid, cell, scale = config['idleSource']
        w, _, pixels = read_png(self.pack / relative)
        size = w // grid
        source = crop(pixels, w, (cell % grid) * size, (cell // grid) * size, size, size)
        clear_haze(source)
        box = face_box(source, size, config['face'])
        # The head scale every frame is matched to: idle-00's source face width at its v1 packing scale.
        self.face_width = (box[2] - box[0]) * scale
        _, _, idle = read_png(self.pack / 'frames/idle-00.png')
        self.idle = idle
        self.idle_face = face_box(idle, CANVAS, config['face'])
        self.face_cx = (self.idle_face[0] + self.idle_face[2]) / 2
        column = round(self.face_cx)
        skull = next(y for y in range(CANVAS) if idle[(y * CANVAS + column) * 4 + 3] > 128)
        self.skull_offset = self.idle_face[1] - skull
        self.head = [column, skull]

    def sheet(self, stem):
        if stem not in self.sheets:
            path = self.pack / 'sources' / f'{stem}-sheet.png'
            w, h, pixels = read_png(path)
            assert (w, h) == (SHEET, SHEET), path
            self.sheets[stem] = pixels
        return self.sheets[stem]

    def cell(self, stem, index):
        """The cell plus PAD on every side, keeping only connected art whose centre is in the cell."""
        sheet, side = self.sheet(stem), CELL + 2 * PAD
        x0, y0 = (index % GRID) * CELL - PAD, (index // GRID) * CELL - PAD
        region = bytearray(side * side * 4)
        for y in range(side):
            if 0 <= y0 + y < SHEET:
                left, right = max(0, x0), min(SHEET, x0 + side)
                region[(y * side + left - x0) * 4:(y * side + right - x0) * 4] = sheet[((y0 + y) * SHEET + left) * 4:((y0 + y) * SHEET + right) * 4]
        fringe_before = fringe(region, side)
        dropped = clear_haze(region)
        foreign = 0
        for part in components(region, side, side, lambda r, g, b, a: a > 0, eight=True):
            cx = sum(i % side for i in part['members']) / part['area']
            cy = sum(i // side for i in part['members']) / part['area']
            if not (PAD <= cx < PAD + CELL and PAD <= cy < PAD + CELL):
                foreign += part['area']
                for i in part['members']:
                    region[i * 4:i * 4 + 4] = b'\0\0\0\0'
        return region, side, fringe_before, dropped, foreign

    def pack_frame(self, name):
        stem, index = CELLS[name]
        cell, side, fringe_before, dropped, foreign = self.cell(stem, index)
        silhouette = alpha_box(cell, side)
        margin = min(silhouette[0], silhouette[1], side - silhouette[2], side - silhouette[3])
        if margin < 2:
            raise ValueError(f'{self.id} {name}: art reaches the edge of the padded {stem} cell {index}')
        face = face_box(cell, side, self.config['face'])
        scale = self.face_width / (face[2] - face[0])
        size = round(side * scale)
        resized = resample(cell, side, side, size, size, self.work)
        dropped_after = clear_haze(resized)
        scaled_face = face_box(resized, size, self.config['face'])
        dx = round(self.face_cx - (scaled_face[0] + scaled_face[2]) / 2)
        box = alpha_box(resized, size)
        dy = ANCHOR[1] - box[3]
        record = {
            'sourceSheet': f'sources/{stem}-sheet.png', 'sourceCell': index, 'cellPadding': PAD,
            'sourceFaceBounds': face, 'sourceAlphaBounds': silhouette, 'paddedCellMargin': margin,
            'neighbourPixelsDropped': foreign,
            'scale': round(scale, 5), 'scaledCellSize': size, 'translation': [dx, dy],
        }
        placed = [box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy]
        if placed[0] < 0 or placed[1] < 0 or placed[2] > CANVAS:
            # At idle-00's head scale the pose does not fit the canvas. It is never cropped: the frame
            # is left out and reported with the bounds it would need.
            record.update({'canvasOverflow': True, 'alphaBounds': placed})
            return None, record
        output = place(resized, size, size, dx, dy, f'{self.id} {name}')
        out_face = face_box(output, CANVAS, self.config['face'])
        head = [round((out_face[0] + out_face[2]) / 2), out_face[1] - self.skull_offset]
        record.update({
            'faceBounds': out_face,
            'headScale': round((out_face[2] - out_face[0]) / (self.idle_face[2] - self.idle_face[0]), 4),
            'alphaBounds': alpha_box(output),
            'hazePixelsDropped': [dropped, dropped_after],
            'redFringePixels': [fringe_before, fringe(output, CANVAS)],
            'head': head,
        })
        return output, record

    def nozzle(self, pixels, record):
        """The open end of the steel nozzle: the steel region's point furthest down-left."""
        regions = [r for r in components(pixels, CANVAS, CANVAS, steel, eight=True)
                   if r['area'] >= 12 and r['box'][0] < self.face_cx]
        if not regions:
            raise ValueError('No nozzle region')
        tip = max(regions[0]['members'], key=lambda i: (i // CANVAS) - (i % CANVAS))
        return [tip % CANVAS, tip // CANVAS]

    def hand(self, pixels, record):
        """The raised limb: Little Chris's highest hand, Mona's curled tip beside the face."""
        face = record['faceBounds']
        if self.config['face'] is skin_face:
            hands = [r for r in components(pixels, CANVAS, CANVAS, skin_face)[1:] if r['area'] >= 40]
            region = min(hands, key=lambda r: r['box'][1])['members']
        else:
            band = range(face[1] + (face[3] - face[1]) // 2, face[3] + 30)
            region = [y * CANVAS + x for y in band for x in range(face[2] + 4, CANVAS)
                      if pixels[(y * CANVAS + x) * 4 + 3] > 128]
        return [round(sum(i % CANVAS for i in region) / len(region)), round(sum(i // CANVAS for i in region) / len(region))]

    def hat(self):
        """The props-reference helmet, cut out of cell 0, resampled to the brim width and placed on idle-00."""
        w, _, pixels = read_png(MASCOTS / 'shared-fx-v1/sources/props-reference.png')
        cell = crop(pixels, w, 0, 0, CELL, CELL)
        clear_haze(cell)
        x0, y0, x1, y1 = alpha_box(cell, CELL)
        cut = crop(cell, CELL, x0, y0, x1 - x0, y1 - y0)
        k = self.config['brim'] / (x1 - x0)
        hw, hh = self.config['brim'], round((y1 - y0) * k)
        helmet = resample(cut, x1 - x0, y1 - y0, hw, hh, self.work)
        clear_haze(helmet)
        shield = components(helmet, hw, hh, lambda r, g, b, a: a > 128 and r > 200 and g > 180 and b > 130 and r - b < 80)[0]['box']
        shield_cx = (shield[0] + shield[2]) / 2
        # Crown at y >= 20; otherwise the brim's lowest edge overlaps the top of idle-00's face by 6 px.
        top = max(self.config['union'][2], self.idle_face[1] + 6 - hh)
        dx, dy = round(self.head[0] - shield_cx), top
        overlay = place(helmet, hw, hh, dx, dy, f'{self.id} hat')
        return overlay, {'source': 'shared-fx-v1/sources/props-reference.png', 'sourceCell': 0,
                         'sourceAlphaBounds': [x0, y0, x1, y1], 'size': [hw, hh], 'scale': round(k, 5),
                         'translation': [dx, dy], 'shieldCentreX': shield_cx, 'alphaBounds': alpha_box(overlay)}

    def helmet_cover(self, pixels, hat, offset):
        """Generated helmet pixels (red parts above the face, their row spans and a 2 px outline) the hat leaves showing."""
        face_top = face_box(pixels, CANVAS, self.config['face'])[1]
        mask = bytearray(CANVAS * CANVAS)
        for region in components(pixels, CANVAS, CANVAS, red):
            if region['box'][1] < face_top + 10 and region['area'] >= 20:
                for i in region['members']:
                    mask[i] = 1
        for y in range(CANVAS):
            xs = [x for x in range(CANVAS) if mask[y * CANVAS + x]]
            for x in range(xs[0], xs[-1] + 1) if xs else ():
                mask[y * CANVAS + x] = 1
        core = sum(mask)
        exposed, exposed_core, over_face = 0, 0, 0
        box = [CANVAS, CANVAS, -1, -1]
        dx, dy = offset
        for y in range(CANVAS):
            for x in range(CANVAS):
                near = any(mask[ny * CANVAS + nx] for ny in range(max(0, y - 2), min(CANVAS, y + 3))
                           for nx in range(max(0, x - 2), min(CANVAS, x + 3)))
                if not near or pixels[(y * CANVAS + x) * 4 + 3] == 0:
                    continue
                sx, sy = x - dx, y - dy
                covered = 0 <= sx < CANVAS and 0 <= sy < CANVAS and hat[(sy * CANVAS + sx) * 4 + 3] >= 128
                if not covered:
                    exposed += 1
                    exposed_core += mask[y * CANVAS + x]
                    box = [min(box[0], x), min(box[1], y), max(box[2], x + 1), max(box[3], y + 1)]
        return {'helmetPixels': core, 'exposedPixels': exposed, 'exposedHelmetCore': exposed_core,
                'exposedBounds': box if exposed else None}


def violations(box, union):
    left, right, top = union
    found = {}
    if box[0] < left:
        found['left'] = left - box[0]
    if box[2] - 1 > right:
        found['right'] = box[2] - 1 - right
    if box[1] < top:
        found['top'] = top - box[1]
    return found


def build_skin(pack_id, config, work):
    skin = Skin(pack_id, config, work)
    pack = skin.pack
    manifest = json.loads((pack / 'manifest.json').read_text())
    core = {state: manifest['states'][state] for state in ['idle', 'attention', 'urgent']}
    core_hashes = {path: manifest['frameSha256'][path] for spec in core.values() for path in spec['frames'] + [spec['staticFallback']]}
    for path, digest in core_hashes.items():
        if sha256_png(pack / path) != digest:
            raise ValueError(f'{pack_id}: v1 frame {path} changed')

    frames, records = {}, {}
    for name in CELLS:
        pixels, records[name] = skin.pack_frame(name)
        if pixels is None:
            (pack / f'frames/{name}.png').unlink(missing_ok=True)
        else:
            frames[name] = pixels
        print(f'{pack_id} {name}: scale {records[name]["scale"]} head {records[name].get("headScale")} '
              f'bounds {records[name]["alphaBounds"]}', flush=True)
    hat, hat_record = skin.hat()

    def offset(name):
        head = records.get(name, {}).get('head', skin.head)
        return head[0] - skin.head[0], head[1] - skin.head[1]

    helmet = {name: skin.helmet_cover(frames[name], hat, offset(name)) if name in frames else 'not packed (canvas overflow)'
              for name in HELMET_ON}
    replace = HELMET_REPLACEMENT == 'apply' or (
        HELMET_REPLACEMENT == 'evaluate' and all(isinstance(r, dict) and r['exposedPixels'] == 0 for r in helmet.values()))
    for name in [n for n in HELMET_ON if n in frames] if replace else []:
        frames[name] = over(frames[name], hat, *offset(name))
        records[name]['alphaBounds'] = alpha_box(frames[name])
    frames['incident-start-05'] = over(skin.idle, hat)
    records['incident-start-05'] = {'composite': 'frames/idle-00.png + accessories/firefighter-hat.png',
                                    'alphaBounds': alpha_box(frames['incident-start-05']), 'head': skin.head}

    hashes = dict(core_hashes)
    for name, pixels in frames.items():
        write_png(pack / f'frames/{name}.png', CANVAS, CANVAS, pixels)
        hashes[f'frames/{name}.png'] = sha256_png(pack / f'frames/{name}.png')
    write_png(pack / 'accessories/firefighter-hat.png', CANVAS, CANVAS, hat)
    hashes['accessories/firefighter-hat.png'] = sha256_png(pack / 'accessories/firefighter-hat.png')

    def path(name):
        return f'frames/{name}.png'

    def packed(names):
        return all(n == 'idle-00' or n in frames for n in names)

    # A held state or clip that needs a frame left out (canvas overflow) is omitted, so the pack
    # falls back to today's behaviour for it instead of playing a partial sequence.
    omitted = {}
    states = dict(core)
    for state, (names, durations) in HELD.items():
        if not packed(names):
            omitted[state] = sorted({n for n in names if n not in frames})
            continue
        states[state] = {'frames': [path(n) for n in names], 'durationMs': durations, 'loop': True, 'staticFallback': path(names[0])}
    clips = {}
    for clip, (names, durations, accessories) in CLIPS.items():
        if not packed(names):
            omitted[clip] = sorted({n for n in names if n != 'idle-00' and n not in frames})
            continue
        clips[clip] = {'frames': [path(n) for n in names], 'durationMs': durations}
        if accessories:
            clips[clip]['accessories'] = accessories
    used = {Path(p).stem for spec in [*states.values(), *clips.values()] for p in spec['frames']}
    frame_points = {}
    for name, record in sorted(records.items()):
        if name in used and record['head'] != skin.head:
            frame_points.setdefault(path(name), {})['head'] = record['head']
    for name in ['incident-end-02', 'incident-end-03']:
        if name in frames:
            records[name]['nozzle'] = skin.nozzle(frames[name], records[name])
            if name in used:
                frame_points.setdefault(path(name), {})['nozzle'] = records[name]['nozzle']
    if 'item-cleared-01' in frames:
        records['item-cleared-01']['hand'] = skin.hand(frames['item-cleared-01'], records['item-cleared-01'])
        if 'item-cleared-01' in used:
            frame_points.setdefault(path('item-cleared-01'), {})['hand'] = records['item-cleared-01']['hand']

    referenced = sorted({p for spec in states.values() for p in spec['frames'] + [spec['staticFallback']]}
                        | {p for spec in clips.values() for p in spec['frames']} | {'accessories/firefighter-hat.png'})
    manifest = {'schemaVersion': 2, 'id': manifest['id'], 'name': manifest['name'],
                'canvas': {'width': CANVAS, 'height': CANVAS}, 'anchor': ANCHOR, 'states': states, 'clips': clips,
                'accessories': {'firefighter-hat': {'image': 'accessories/firefighter-hat.png', 'attach': 'head'}},
                'points': {'head': skin.head}, 'framePoints': dict(sorted(frame_points.items())),
                'frameSha256': {p: hashes[p] for p in referenced}}
    (pack / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

    # Bounds rule (section 3): every new frame, and the hat wherever it can show, at alpha > 0.
    wearing = {p for spec in states.values() for p in spec['frames']} | {p for spec in clips.values() if 'accessories' not in spec for p in spec['frames']}
    bounds_report = {}
    for name, record in sorted(records.items()):
        found = violations(record['alphaBounds'], config['union'])
        if found:
            bounds_report[path(name)] = found
    hat_box = alpha_box(hat)
    for p in sorted(wearing):
        name = Path(p).stem
        dx, dy = offset(name)
        found = violations([hat_box[0] + dx, hat_box[1] + dy, hat_box[2] + dx, hat_box[3] + dy], config['union'])
        if found:
            bounds_report[f'{p} + hat'] = found

    packing_path = pack / 'packing.json'
    packing = json.loads(packing_path.read_text()) if packing_path.exists() else {}
    packing['v2'] = {
        'builder': 'docs/design/build_pack_v2.py',
        'rules': ['one generated cell per runtime frame; no pixel drawn or synthesized',
                  f'alpha <= {HAZE_ALPHA} dropped before and after resampling',
                  'resampled with macOS sips so the face width matches idle-00 (headScale is the result)',
                  'face centre aligned to idle-00, lowest visible pixel on y 232',
                  'points measured from masks: head = face top minus the idle-00 face-to-skull offset'],
        'faceWidthTarget': round(skin.face_width, 3), 'idleFaceBounds': skin.idle_face, 'skullOffset': skin.skull_offset,
        'union': {'x': list(config['union'][:2]), 'yMin': config['union'][2]},
        'excludedCells': EXCLUDED,
        'helmetReplacement': {'mode': HELMET_REPLACEMENT, 'applied': replace, 'frames': helmet},
        'accessory': hat_record,
        'frames': records,
        'boundsViolations': bounds_report,
        'omittedFromManifest': omitted,
        'sourceSha256': {str(p.relative_to(pack)): sha256_png(p) for p in sorted((pack / 'sources').glob('*-sheet.png'))
                         if p.stem.removesuffix('-sheet') in {stem for stem, _ in CELLS.values()}}
                        | {'shared-fx-v1/sources/props-reference.png': sha256_png(MASCOTS / 'shared-fx-v1/sources/props-reference.png')},
    }
    packing_path.write_text(json.dumps(packing, indent=2) + '\n')
    return packing['v2']


# Shared FX (section 4): a 2 x 4 sheet in reading order, 64 x 64 with a 4 px clear margin.
FX = ['fx-mist-00', 'fx-mist-01', 'fx-mist-02', 'fx-smoke-00', 'fx-smoke-01', 'fx-sparkle-00', 'fx-sparkle-01', 'fx-z']
FX_SIZE, FX_MARGIN = 64, 4


def build_fx(work):
    pack = MASCOTS / 'shared-fx-v1'
    w, h, pixels = read_png(pack / 'sources/fx-sheet.png')
    rows = [round(r * h / 4) for r in range(5)]
    cells = {}
    for index, name in enumerate(FX):
        column, row = index % 2, index // 2
        x, y = column * (w // 2), rows[row]
        cell = crop(pixels, w, x, y, w // 2, rows[row + 1] - y)
        dropped = clear_haze(cell)
        box = alpha_box(cell, w // 2)
        if min(box[0], box[1], w // 2 - box[2], rows[row + 1] - y - box[3]) < 2:
            raise ValueError(f'{name}: sprite touches its cell edge')
        cells[name] = (cell, box, dropped)
    # One scale per family, so the smaller twinkle stays smaller than the sparkle.
    families = {}
    for name in FX:
        families.setdefault(name.rsplit('-', 1)[0] if name[-1].isdigit() else name, []).append(name)
    records = {}
    for family, names in families.items():
        side = max(max(b[2] - b[0], b[3] - b[1]) for _, b, _ in (cells[n] for n in names))
        for name in names:
            cell, box, dropped = cells[name]
            cw = w // 2
            cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
            square = bytearray(side * side * 4)
            for sy in range(side):
                for sx in range(side):
                    ox, oy = cx - side // 2 + sx, cy - side // 2 + sy
                    if 0 <= ox < cw and 0 <= oy < len(cell) // 4 // cw:
                        square[(sy * side + sx) * 4:(sy * side + sx) * 4 + 4] = cell[(oy * cw + ox) * 4:(oy * cw + ox) * 4 + 4]
            inner = FX_SIZE - 2 * FX_MARGIN
            scaled = resample(square, side, side, inner, inner, work)
            dropped_after = clear_haze(scaled)
            sprite = bytearray(FX_SIZE * FX_SIZE * 4)
            for y in range(inner):
                start = ((y + FX_MARGIN) * FX_SIZE + FX_MARGIN) * 4
                sprite[start:start + inner * 4] = scaled[y * inner * 4:(y + 1) * inner * 4]
            write_png(pack / f'{name}.png', FX_SIZE, FX_SIZE, sprite)
            records[name] = {'sourceCell': FX.index(name), 'sourceAlphaBounds': box, 'familySide': side,
                             'scale': round(inner / side, 5), 'hazePixelsDropped': [dropped, dropped_after],
                             'alphaBounds': alpha_box(sprite, FX_SIZE), 'sha256': sha256_png(pack / f'{name}.png')}
    packing = {'builder': 'docs/design/build_pack_v2.py', 'size': [FX_SIZE, FX_SIZE], 'clearMargin': FX_MARGIN,
               'sourceSha256': {'sources/fx-sheet.png': sha256_png(pack / 'sources/fx-sheet.png')}, 'sprites': records}
    (pack / 'packing.json').write_text(json.dumps(packing, indent=2) + '\n')
    return records


def main():
    only = sys.argv[1:]
    with tempfile.TemporaryDirectory(prefix='pack-v2-') as temp:
        work = Path(temp)
        if not only or 'fx' in only:
            build_fx(work)
        for pack_id, config in SKINS.items():
            if not only or pack_id in only:
                build_skin(pack_id, config, work)
    print('Packed v2 art')


if __name__ == '__main__':
    main()
