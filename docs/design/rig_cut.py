"""Check and cut a rig parts sheet into islands (#138, docs/design/animation-v2-rig.md section 6).

  python3 -B docs/design/rig_cut.py --check <sheet.png> [--expect N]
  python3 -B docs/design/rig_cut.py --cut <sheet.png> --out <dir>

An island is an 8-connected group of pixels with alpha > 8. --check prints the islands in reading
order (row bands, then left to right) with their boxes and areas, and flags what section 6.3 asks
the PM to reject: a non-transparent background, specks, islands closer than the 40 px gap, and a
count that differs from --expect. --cut writes each island, cropped with a 4 px margin, as
<dir>/island-NN.png plus <dir>/islands.json. It never draws or edits pixels.
"""
import argparse
import json
import sys
from pathlib import Path

from png_rgba import crop, read_png, write_png

ALPHA = 8
MIN_GAP = 40
SPECK_AREA = 150
MARGIN = 4


def islands(width, height, pixels):
    """Connected components of alpha > ALPHA, as dicts with box [x0, y0, x1, y1) and area."""
    solid = bytearray(1 if pixels[i * 4 + 3] > ALPHA else 0 for i in range(width * height))
    label = [0] * (width * height)
    found = []
    for start in range(width * height):
        if not solid[start] or label[start]:
            continue
        number = len(found) + 1
        label[start] = number
        stack = [start]
        x0, y0, x1, y1, area = width, height, -1, -1, 0
        while stack:
            i = stack.pop()
            x, y = i % width, i // width
            area += 1
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
            for dy in (-1, 0, 1):
                ny = y + dy
                if not 0 <= ny < height:
                    continue
                for dx in (-1, 0, 1):
                    nx = x + dx
                    if 0 <= nx < width:
                        j = ny * width + nx
                        if solid[j] and not label[j]:
                            label[j] = number
                            stack.append(j)
        found.append({'label': number, 'box': [x0, y0, x1 + 1, y1 + 1], 'area': area})
    return found, label


def reading_order(found):
    """Row bands: an island joins the current band when its vertical centre lies inside the band."""
    rest = sorted(found, key=lambda island: island['box'][1])
    rows = []
    for island in rest:
        centre = (island['box'][1] + island['box'][3]) / 2
        if rows and rows[-1]['top'] <= centre <= rows[-1]['bottom']:
            rows[-1]['items'].append(island)
            rows[-1]['bottom'] = max(rows[-1]['bottom'], island['box'][3])
        else:
            rows.append({'top': island['box'][1], 'bottom': island['box'][3], 'items': [island]})
    ordered = []
    for number, row in enumerate(rows):
        for island in sorted(row['items'], key=lambda item: item['box'][0]):
            island['row'] = number
            ordered.append(island)
    return ordered


def box_gap(a, b):
    """Gap between two boxes (0 when they overlap): a lower bound on the islands' pixel distance."""
    dx = max(b[0] - a[2], a[0] - b[2], 0)
    dy = max(b[1] - a[3], a[1] - b[3], 0)
    return max(dx, dy)


def report(path, expect=None):
    width, height, pixels = read_png(path)
    problems = []
    corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    if any(pixels[(y * width + x) * 4 + 3] for x, y in corners):
        problems.append('background: a corner pixel is not fully transparent')
    found, _ = islands(width, height, pixels)
    parts = reading_order([island for island in found if island['area'] >= SPECK_AREA])
    specks = [island for island in found if island['area'] < SPECK_AREA]
    haze = sum(1 for i in range(3, len(pixels), 4) if 0 < pixels[i] <= ALPHA)
    lines = [f'{path}: {width} x {height}, {len(parts)} islands, {len(specks)} specks, {haze} faint pixels (alpha 1-{ALPHA})']
    for number, island in enumerate(parts):
        x0, y0, x1, y1 = island['box']
        lines.append(f'  {number:02d} row {island["row"]}  box x {x0}-{x1} y {y0}-{y1}  {x1 - x0} x {y1 - y0}  area {island["area"]}')
    for a in range(len(parts)):
        for b in range(a + 1, len(parts)):
            gap = box_gap(parts[a]['box'], parts[b]['box'])
            if gap < MIN_GAP:
                problems.append(f'gap: islands {a:02d} and {b:02d} are within {gap} px (boxes), need {MIN_GAP}')
    if expect is not None and len(parts) != expect:
        problems.append(f'count: {len(parts)} islands, expected {expect}')
    if specks:
        # The cutter drops them; list them so a broken-off piece of a part is noticed by eye.
        where = ', '.join(f'({s["box"][0]},{s["box"][1]})' for s in specks[:12]) + (' ...' if len(specks) > 12 else '')
        lines.append(f'  NOTE {len(specks)} specks under {SPECK_AREA} px are ignored: {where}')
    lines += [f'  PROBLEM {problem}' for problem in problems] or ['  OK: transparent, separable']
    return '\n'.join(lines), parts, (width, height, pixels), not problems


def cut(path, out):
    text, parts, (width, height, pixels), _ = report(path)
    _, label = islands(width, height, pixels)
    manifest = []
    for number, island in enumerate(parts):
        x0, y0, x1, y1 = island['box']
        cx0, cy0 = max(0, x0 - MARGIN), max(0, y0 - MARGIN)
        cx1, cy1 = min(width, x1 + MARGIN), min(height, y1 + MARGIN)
        w, h = cx1 - cx0, cy1 - cy0
        piece = crop(pixels, width, cx0, cy0, w, h)
        # Keep only this island's pixels (a neighbour's edge can fall inside the margin).
        for row in range(h):
            for column in range(w):
                if label[(cy0 + row) * width + cx0 + column] != island['label']:
                    piece[(row * w + column) * 4:(row * w + column) * 4 + 4] = b'\0\0\0\0'
        name = f'island-{number:02d}.png'
        write_png(out / name, w, h, piece)
        manifest.append({'file': name, 'row': island['row'], 'sheetBox': [cx0, cy0, cx1, cy1], 'area': island['area']})
    (out / 'islands.json').write_text(json.dumps({'sheet': str(path), 'islands': manifest}, indent=2) + '\n')
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', type=Path, metavar='SHEET')
    mode.add_argument('--cut', type=Path, metavar='SHEET')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--expect', type=int)
    args = parser.parse_args(argv)
    if args.check:
        text, _, _, ok = report(args.check, args.expect)
        print(text)
        return 0 if ok else 1
    if not args.out:
        parser.error('--cut needs --out')
    print(cut(args.cut, args.out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
