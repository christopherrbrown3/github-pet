#!/usr/bin/env python3
"""Validate real pack files against the developer-agreed v1 contract and the #138 schema v2 additions."""
from pathlib import Path
import hashlib
import json
import sys
from png_rgba import bounds, read_png, sha256_png

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / 'assets/mascots/mona-pet-v1'
PACKS = {'mona-pet-v1': (47, 217, 20), 'little-chris-v1': (62, 205, 20)}
# animation-v1.md section 4: clip keys and length caps (ms), held states, the bundled design budget.
CLIP_CAPS = {'incident-start': 2200, 'incident-end': 3200, 'new-item': 1900, 'item-cleared': 1500, 'inbox-zero': 2400,
             'drop': 1200, 'poke': 1200, 'dizzy': 1800, 'idle-look': 2600, 'idle-stretch': 2600, 'idle-fidget': 2600}
HELD = {'drag', 'doze', 'incident-idle', 'drag-incident'}
# Frame sequences (#138): 16-frame clips at ~70 ms per frame.
MAX_SEQUENCE, MAX_IMAGES, MAX_IMAGE_BYTES, MAX_PACK_BYTES = 16, 256, 96 * 1024, 16 * 1024 * 1024
CLIP_FRAME_MS = (40, 2000)


def check_pack(pack, union=PACKS['mona-pet-v1']):
    manifest = json.loads((pack / 'manifest.json').read_text())
    assert manifest['schemaVersion'] in (1, 2)
    assert manifest['canvas'] == {'width': 256, 'height': 256}
    assert manifest['anchor'] == [128, 232]
    results, decoded, unique = {}, 0, set()

    def resolve(relative):
        assert isinstance(relative, str) and relative.endswith('.png')
        path = Path(relative)
        assert not path.is_absolute() and '..' not in path.parts
        target = (pack / path).resolve(strict=True)
        assert target.is_relative_to(pack.resolve())
        return target

    for state in ['idle', 'attention', 'urgent']:
        clip = manifest['states'][state]
        assert isinstance(clip['loop'], bool)
        assert 1 <= len(clip['frames']) <= 12
        assert len(clip['frames']) == len(clip['durationMs'])
        assert all(type(t) is int and 125 <= t <= 2000 for t in clip['durationMs'])
        # Little Chris's attention falls back to idle-00, so any state frame is accepted.
        assert clip['staticFallback'] in {f for spec in manifest['states'].values() for f in spec['frames']}
        poses, checks = set(), []
        for relative in clip['frames']:
            path = resolve(relative)
            width, height, pixels = read_png(path)
            assert (width, height) == (256, 256)
            alpha = pixels[3::4]
            assert min(alpha) == 0 and max(alpha) > 240
            bbox = bounds(pixels, width, lambda r, g, b, a: a > 8)
            assert bbox[0] >= 8 and bbox[1] >= 8 and bbox[2] <= 248, bbox
            # Include every nonzero-alpha pixel, not just the >8 alpha used
            # for clipping-risk bounds. The bottom edge is exclusive.
            visible_bbox = bounds(pixels, width, lambda r, g, b, a: a > 0)
            if bbox[3] != manifest['anchor'][1] or visible_bbox[3] != manifest['anchor'][1]:
                raise ValueError(f'Ground anchor mismatch: {relative}: visible={bbox}, nonzero={visible_bbox}')
            # Borders must be genuinely transparent, not a checkerboard or haze.
            assert all(pixels[(y * 256 + x) * 4 + 3] == 0 for y in range(256) for x in range(256) if x in (0, 255) or y in (0, 255))
            digest = sha256_png(path)
            assert manifest['frameSha256'][relative] == digest
            poses.add(digest)
            if relative not in unique:
                decoded += len(pixels)
                unique.add(relative)
            checks.append({'path': relative, 'size': [width, height], 'alphaRange': [min(alpha), max(alpha)],
                           'fullyTransparentPixels': alpha.count(0), 'boundsAlphaOver8': bbox,
                           'visibleBottomAlphaOver0': visible_bbox[3], 'sha256': digest})
        assert len(poses) >= 2, f'{state} must have visible animation keyframes'
        resolve(clip['staticFallback'])
        results[state] = {'loop': clip['loop'], 'durationMs': sum(clip['durationMs']), 'distinctFrames': len(poses), 'files': checks}
    assert manifest['states']['idle']['loop']
    assert not manifest['states']['attention']['loop']
    assert not manifest['states']['urgent']['loop']
    assert sum(manifest['states']['attention']['durationMs']) <= 2000
    assert sum(manifest['states']['urgent']['durationMs']) <= 2000
    # Only Mona records how her v1 frames were packed.
    packing = json.loads((pack / 'packing.json').read_text()) if (pack / 'packing.json').exists() else {}
    for relative, expected in packing.get('sourceSha256', {}).items():
        assert sha256_png(resolve(relative)) == expected
    for sheet in packing.get('sheets', {}).values():
        path = resolve(sheet['path'])
        width, height, _ = read_png(path)
        assert [width, height] == sheet['size'] == [1024, 256]
        assert sha256_png(path) == sheet['sha256']
    v2 = check_v2(pack, manifest, union, resolve) if manifest['schemaVersion'] >= 2 else None
    contract = 'developer v1' + (' + schema v2' if v2 else '')
    return {'result': 'pass', 'contract': contract, 'canvas': [256, 256], 'anchor': [128, 232],
            'states': results, 'decodedRuntimeFrameBytes': decoded, **({'v2': v2} if v2 else {}),
            'manifestSha256': hashlib.sha256((pack / 'manifest.json').read_bytes()).hexdigest(),
            'limitations': ['Source sheets are generated; minor contour variation remains between poses.',
                            'Browser design review is not native app, VoiceOver, or physical display verification.']}


def check_v2(pack, manifest, union, resolve):
    """Section 4 structure, the bundled budget, and the bounds rule (reported, not asserted)."""
    states, clips = manifest['states'], manifest.get('clips', {})
    assert set(states) <= {'idle', 'attention', 'urgent'} | HELD, set(states)
    sequences = {}
    for name in HELD & set(states):
        spec = states[name]
        assert spec['loop'] is True and spec['staticFallback'] in spec['frames'], name
        sequences[name] = spec
    for name, spec in clips.items():
        # Helmet variants (#138) follow their clip's cap.
        base = name[:-len('-incident')] if name.endswith('-incident') and name[:-len('-incident')] in ('poke', 'dizzy', 'drop') else name
        assert base in CLIP_CAPS, f'unknown clip {name}'
        assert 'loop' not in spec and 'staticFallback' not in spec, name
        assert spec.get('accessories', 'keep') in ('keep', 'hide'), name
        assert sum(spec['durationMs']) <= CLIP_CAPS[base], (name, sum(spec['durationMs']))
        sequences[name] = spec
    for name, spec in sequences.items():
        assert 1 <= len(spec['frames']) <= MAX_SEQUENCE and len(spec['frames']) == len(spec['durationMs']), name
        assert all(type(t) is int and CLIP_FRAME_MS[0] <= t <= CLIP_FRAME_MS[1] for t in spec['durationMs']), name
    accessories = manifest.get('accessories', {})
    assert set(accessories) <= {'firefighter-hat'}
    assert all(spec['attach'] == 'head' for spec in accessories.values())
    points = manifest.get('points', {})
    if accessories:
        assert 'head' in points, 'points.head is required with accessories'

    def point(value):
        assert isinstance(value, list) and len(value) == 2 and all(type(v) is int and 0 <= v < 256 for v in value), value

    for value in points.values():
        point(value)
    referenced = {p for spec in states.values() for p in spec['frames'] + [spec['staticFallback']]}
    referenced |= {p for spec in clips.values() for p in spec['frames']} | {spec['image'] for spec in accessories.values()}
    for path, values in manifest.get('framePoints', {}).items():
        assert path in referenced, f'framePoints for unreferenced {path}'
        assert set(values) <= {'head', 'nozzle', 'hand'}
        for value in values.values():
            point(value)
    if 'incident-end' in clips:
        for path in clips['incident-end']['frames'][2:4]:
            assert 'nozzle' in manifest['framePoints'].get(path, {}) or 'nozzle' in points, f'{path} needs a nozzle point'
    assert len(referenced) <= MAX_IMAGES, len(referenced)
    total = 0
    v1_paths = {p for name in ('idle', 'attention', 'urgent') for p in states[name]['frames'] + [states[name]['staticFallback']]}
    frames, violations = {}, {}
    hats = {spec['image']: read_png(resolve(spec['image']))[2] for spec in accessories.values()}
    for relative in sorted(referenced):
        path = resolve(relative)
        size = path.stat().st_size
        assert size <= MAX_IMAGE_BYTES, (relative, size)
        total += size
        width, height, pixels = read_png(path)
        assert (width, height) == (256, 256), relative
        assert manifest['frameSha256'][relative] == sha256_png(path), relative
        assert all(pixels[(y * 256 + x) * 4 + 3] == 0 for y in range(256) for x in range(256) if x in (0, 255) or y in (0, 255)), relative
        box = bounds(pixels, width, lambda r, g, b, a: a > 0)
        if relative in hats:
            frames[relative] = {'boundsAlphaOver0': box}
            continue
        assert box[3] == 232, f'ground anchor mismatch: {relative} {box}'
        frames[relative] = {'boundsAlphaOver0': box, 'bytes': size}
        found = outside(box, union)
        if found and relative not in v1_paths:
            violations[relative] = found
    assert total <= MAX_PACK_BYTES, total
    # The hat wherever it can show: state and held frames, and clips that keep accessories.
    wearing = {p for spec in states.values() for p in spec['frames']} | {p for spec in clips.values() if spec.get('accessories') != 'hide' for p in spec['frames']}
    base = points.get('head')
    for image in hats:
        box = frames[image]['boundsAlphaOver0']
        for relative in sorted(wearing):
            head = manifest.get('framePoints', {}).get(relative, {}).get('head', base)
            dx, dy = head[0] - base[0], head[1] - base[1]
            found = outside([box[0] + dx, box[1] + dy, box[2] + dx, box[3] + dy], union)
            if found:
                violations[f'{relative} + {image}'] = found
    return {'clips': sorted(clips), 'heldStates': sorted(HELD & set(states)), 'images': len(referenced), 'bytes': total,
            'union': {'x': list(union[:2]), 'yMin': union[2]}, 'boundsRule': 'fail' if violations else 'pass',
            'boundsViolations': violations}


def outside(box, union):
    left, right, top = union
    found = {}
    if box[0] < left:
        found['left'] = left - box[0]
    if box[2] - 1 > right:
        found['right'] = box[2] - 1 - right
    if box[1] < top:
        found['top'] = top - box[1]
    return found


if __name__ == '__main__':
    report = {pack_id: check_pack(ROOT / 'assets/mascots' / pack_id, union) for pack_id, union in PACKS.items()}
    output = json.dumps(report, indent=2) + '\n'
    if '--report' in sys.argv:
        (ROOT / 'docs/design/validation.json').write_text(output)
    print(output)
    # Contract failures raise above; a bounds-rule failure is reported and fails the run.
    sys.exit(1 if any(r.get('v2', {}).get('boundsRule') == 'fail' for r in report.values()) else 0)
