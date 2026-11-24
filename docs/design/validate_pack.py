#!/usr/bin/env python3
"""Validate real pack files against the developer-agreed v1 contract and the #138 schema v2 and v3 (rig) additions."""
from pathlib import Path
import hashlib
import json
import sys
from png_rgba import bounds, read_png, sha256_png

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / 'assets/mascots/mona-pet-v1'
PACKS = {'mona-pet-v1': (47, 217, 20), 'little-chris-v1': (62, 205, 20)}
FX = ROOT / 'assets/mascots/shared-fx-v1'
# animation-v1.md section 4: clip keys and length caps (ms), held states, the bundled design budget.
CLIP_CAPS = {'incident-start': 2200, 'incident-end': 3200, 'new-item': 1900, 'item-cleared': 1500, 'inbox-zero': 2400,
             'drop': 600, 'poke': 900, 'dizzy': 1800, 'idle-look': 2600, 'idle-stretch': 2600, 'idle-fidget': 2600}
HELD = {'drag', 'doze'}
MAX_SEQUENCE, MAX_IMAGES, MAX_IMAGE_BYTES, MAX_PACK_BYTES = 8, 64, 96 * 1024, 4 * 1024 * 1024
# animation-v2-rig.md section 7.1 (mirrors RigLimits in Sources/GitHubPetCore/Rig.swift).
RIG_MAX_BONES, RIG_MAX_DEPTH, RIG_MAX_PARTS, RIG_MAX_TRACKS, RIG_MAX_KEYS = 24, 8, 48, 40, 48
RIG_MAX_PART_SIDE, RIG_MAX_PART_BYTES, RIG_MIN_CLIP_MS = 1024, 160 * 1024, 100
RIG_EASES = {'linear', 'hold', 'inOut', 'out', 'in', 'back', 'spring'}
RIG_RANGES = {'x': (-64, 64), 'y': (-64, 64), 'rot': (-180, 180), 'sx': (0.3, 1.5), 'sy': (0.3, 1.5), 'opacity': (0, 1)}


def check_pack(pack, union=PACKS['mona-pet-v1']):
    manifest = json.loads((pack / 'manifest.json').read_text())
    assert manifest['schemaVersion'] in (1, 2, 3)
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
    packing = json.loads((pack / 'packing.json').read_text())
    for relative, expected in packing.get('sourceSha256', {}).items():
        assert sha256_png(resolve(relative)) == expected
    for sheet in packing.get('sheets', {}).values():
        path = resolve(sheet['path'])
        width, height, _ = read_png(path)
        assert [width, height] == sheet['size'] == [1024, 256]
        assert sha256_png(path) == sheet['sha256']
    v2 = check_v2(pack, manifest, union, resolve) if manifest['schemaVersion'] >= 2 else None
    v3 = check_v3(manifest, union, resolve) if manifest['schemaVersion'] >= 3 else None
    contract = 'developer v1' + (' + schema v2' if v2 else '') + (' + schema v3 rig' if v3 else '')
    return {'result': 'pass', 'contract': contract, 'canvas': [256, 256], 'anchor': [128, 232],
            'states': results, 'decodedRuntimeFrameBytes': decoded, **({'v2': v2} if v2 else {}), **({'v3': v3} if v3 else {}),
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
        assert name in CLIP_CAPS, f'unknown clip {name}'
        assert 'loop' not in spec and 'staticFallback' not in spec, name
        assert spec.get('accessories', 'keep') in ('keep', 'hide'), name
        assert sum(spec['durationMs']) <= CLIP_CAPS[name], (name, sum(spec['durationMs']))
        sequences[name] = spec
    for name, spec in sequences.items():
        assert 1 <= len(spec['frames']) <= MAX_SEQUENCE and len(spec['frames']) == len(spec['durationMs']), name
        assert all(type(t) is int and 125 <= t <= 2000 for t in spec['durationMs']), name
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


def rig_errors(rig):
    """Schema v3 rig rules that need no files; an empty list means valid. Mirrors RigLimits.validate."""
    errors = []
    number = lambda v: type(v) in (int, float) and v == v and abs(v) != float('inf')
    pair = lambda v, limit=512: isinstance(v, list) and len(v) == 2 and all(number(x) and abs(x) <= limit for x in v)
    if not (number(rig.get('unitScale')) and 1 <= rig['unitScale'] <= 8):
        errors.append('unitScale must be 1-8')
    if 'restScale' in rig and not (number(rig['restScale']) and 0.5 <= rig['restScale'] <= 1):
        errors.append('restScale must be 0.5-1')
    bones = rig.get('bones', {})
    if len(bones) > RIG_MAX_BONES:
        errors.append(f'more than {RIG_MAX_BONES} bones')
    if [name for name, bone in bones.items() if bone.get('parent') is None] != ['root']:
        errors.append('exactly one parentless bone, named root')
    for name, bone in sorted(bones.items()):
        if not pair(bone.get('pivot')):
            errors.append(f'bone {name}: pivot must be [x, y]')
        if bone.get('parent') is not None and bone['parent'] not in bones:
            errors.append(f'bone {name}: unknown parent')
        rot = bone.get('rot')
        if rot is not None and not (pair(rot, 180) and rot[0] <= rot[1]):
            errors.append(f'bone {name}: rot must be [min, max]')
        current, depth = bone.get('parent'), 1
        while current is not None and depth <= RIG_MAX_DEPTH + 1:
            current, depth = bones.get(current, {}).get('parent'), depth + 1
        if current is not None:
            errors.append(f'bone {name}: cycle or deeper than {RIG_MAX_DEPTH}')
    reserve = rig.get('reserve')
    if reserve is not None and not (isinstance(reserve, list) and len(reserve) == 3 and all(type(v) is int for v in reserve)
                                    and 0 <= reserve[0] < reserve[2] < 256 and 0 <= reserve[1] < 256):
        errors.append('reserve must be [minX, top, maxX] inside the canvas')
    parts = rig.get('parts', [])
    if not 1 <= len(parts) <= RIG_MAX_PARTS:
        errors.append(f'1-{RIG_MAX_PARTS} parts')
    by_name = {}
    for part in parts:
        name = part.get('name')
        if name in by_name:
            errors.append(f'part {name}: duplicate name')
        by_name[name] = part
        if part.get('bone') not in bones:
            errors.append(f'part {name}: unknown bone')
        if not pair(part.get('origin')):
            errors.append(f'part {name}: origin must be [x, y]')
        if {'default', 'hide'} & set(part.get('variants', {})):
            errors.append(f'part {name}: default and hide are reserved')
        for mount_name, mount in sorted(part.get('mounts', {}).items()):
            if mount_name == 'default' or mount.get('bone') not in bones or not pair(mount.get('origin')):
                errors.append(f'part {name}: bad mount {mount_name}')

    def variant_ok(part, variant):
        return part in by_name and (variant in ('default', 'hide') or variant in by_name[part].get('variants', {}))

    faces = rig.get('faces', {})
    for preset, layers in sorted(faces.items()):
        errors += [f'face {preset}: bad {part} variant' for part, variant in sorted(layers.items()) if not variant_ok(part, variant)]

    def channel_errors(where, track, values):
        bone, _, channel = track.partition('.')
        if bone not in bones or channel not in RIG_RANGES or track.count('.') != 1:
            return [f'{where}: unknown track {track}']
        low, high = RIG_RANGES[channel]
        if channel == 'rot' and 'rot' in bones[bone]:
            low, high = bones[bone]['rot']
        return [f'{where}: {track} value outside {low}..{high}'] if not all(number(v) and low <= v <= high for v in values) else []

    poses = rig.get('poses', {})
    for name, pose in sorted(poses.items()):
        if pose.get('face') is not None and pose['face'] not in faces:
            errors.append(f'pose {name}: unknown face')
        for track, value in sorted(pose.get('channels', {}).items()):
            errors += channel_errors(f'pose {name}', track, [value])
    for name, clip in sorted(rig.get('clips', {}).items()):
        if name not in CLIP_CAPS:
            errors.append(f'unknown clip {name}')
            continue
        duration = clip.get('durationMs')
        if not (type(duration) is int and RIG_MIN_CLIP_MS <= duration <= CLIP_CAPS[name]):
            errors.append(f'clip {name}: durationMs must be {RIG_MIN_CLIP_MS}-{CLIP_CAPS[name]}')
            continue
        within = lambda t: number(t) and 0 <= t <= duration
        tracks = list(clip.get('tracks', {}).items()) + list(clip.get('worn', {}).items())
        if len(tracks) > RIG_MAX_TRACKS:
            errors.append(f'clip {name}: more than {RIG_MAX_TRACKS} tracks')
        for track, keys in tracks:
            if not (isinstance(keys, list) and 1 <= len(keys) <= RIG_MAX_KEYS):
                errors.append(f'clip {name}: {track} needs 1-{RIG_MAX_KEYS} keys')
                continue
            if not all(isinstance(k, list) and len(k) in (2, 3) and (len(k) == 2 or k[2] in RIG_EASES) for k in keys):
                errors.append(f'clip {name}: {track} keys are [ms, value, ease?] with a known ease')
                continue
            times = [k[0] for k in keys]
            if not all(within(t) for t in times) or times != sorted(times):
                errors.append(f'clip {name}: {track} key times must rise within the clip')
            errors += channel_errors(f'clip {name}', track, [k[1] for k in keys])
        for follow in clip.get('follow', []):
            if follow.get('bone') not in bones or follow.get('of') not in bones or not (number(follow.get('delayMs')) and 0 <= follow['delayMs'] <= 1000) \
                    or not (number(follow.get('gain')) and -3 <= follow['gain'] <= 3):
                errors.append(f'clip {name}: bad follow')
        for sway in clip.get('sway', []):
            if any(b not in bones for b in sway.get('bones', [])) or not (number(sway.get('amp')) and 0 <= sway['amp'] <= 45) \
                    or not (number(sway.get('periodMs')) and 100 <= sway['periodMs'] <= 5000) or not 0 <= sway.get('phaseStepMs', 0) <= 2000:
                errors.append(f'clip {name}: bad sway')
        for swap in clip.get('swaps', []):
            if not variant_ok(swap.get('part'), swap.get('variant')) or not within(swap.get('at')):
                errors.append(f'clip {name}: bad swap')
        for face in clip.get('faces', []):
            if face.get('preset') not in faces or not within(face.get('at')):
                errors.append(f'clip {name}: bad face')
        for mount in clip.get('mounts', []):
            part = by_name.get(mount.get('part'), {})
            if not part or (mount.get('mount') != 'default' and mount.get('mount') not in part.get('mounts', {})) \
                    or not within(mount.get('at')) or not 0 <= mount.get('blendMs', 0) <= 2000:
                errors.append(f'clip {name}: bad mount')
        if clip.get('endsOn') is not None and clip['endsOn'] not in poses:
            errors.append(f'clip {name}: endsOn is not a pose')
        if clip.get('accessories', 'keep') not in ('keep', 'hide'):
            errors.append(f'clip {name}: accessories is keep or hide')
    return errors


def check_v3(manifest, union, resolve):
    """Schema v3: rig structure, part images, and (bundled) a reserve equal to the skin's union, so the
    lane and hover never change. The loader samples every clip at 60 Hz against the reserve (the
    bounds rule); render-check loads the bundled packs with the bundled budget, so it enforces that."""
    rig = manifest.get('rig')
    assert isinstance(rig, dict), 'schema 3 needs a rig section'
    errors = rig_errors(rig)
    assert not errors, errors
    reserve = rig.get('reserve')
    assert reserve == [union[0], union[2], union[1]], f'reserve {reserve} must equal the skin union {list(union)} (minX, top, maxX)'
    paths = list(dict.fromkeys(p for part in rig['parts'] for p in [part['image']] + sorted(part.get('variants', {}).values())))
    total = 0
    for relative in paths:
        path = resolve(relative)
        size = path.stat().st_size
        assert size <= RIG_MAX_PART_BYTES, (relative, size)
        total += size
        width, height, pixels = read_png(path)
        assert 1 <= width <= RIG_MAX_PART_SIDE and 1 <= height <= RIG_MAX_PART_SIDE, (relative, width, height)
        assert manifest['frameSha256'][relative] == sha256_png(path), relative
        # Parts are cut with a clear margin: an opaque edge would show a hard seam when rotated.
        assert all(pixels[(y * width + x) * 4 + 3] == 0 for y in range(height) for x in range(width)
                   if x in (0, width - 1) or y in (0, height - 1)), f'{relative} touches its edge'
    return {'bones': len(rig['bones']), 'parts': len(rig['parts']), 'images': len(paths), 'bytes': total,
            'clips': sorted(rig.get('clips', {})), 'poses': sorted(rig.get('poses', {})), 'faces': sorted(rig.get('faces', {})),
            'reserve': reserve, 'boundsRule': 'sampled by the app loader (render-check)'}


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


def check_fx(directory=FX):
    """Shared FX sprites: 64 x 64 RGBA with a 4 px clear margin."""
    names = ['fx-mist-00', 'fx-mist-01', 'fx-mist-02', 'fx-smoke-00', 'fx-smoke-01', 'fx-sparkle-00', 'fx-sparkle-01', 'fx-z']
    report = {}
    for name in names:
        width, height, pixels = read_png(directory / f'{name}.png')
        assert (width, height) == (64, 64), name
        box = bounds(pixels, width, lambda r, g, b, a: a > 0)
        assert box[0] >= 4 and box[1] >= 4 and box[2] <= 60 and box[3] <= 60, (name, box)
        report[name] = {'boundsAlphaOver0': box, 'bytes': (directory / f'{name}.png').stat().st_size}
    return {'result': 'pass', 'sprites': report}


if __name__ == '__main__':
    report = {pack_id: check_pack(ROOT / 'assets/mascots' / pack_id, union) for pack_id, union in PACKS.items()}
    if FX.joinpath('fx-z.png').exists():
        report['shared-fx-v1'] = check_fx()
    output = json.dumps(report, indent=2) + '\n'
    if '--report' in sys.argv:
        (ROOT / 'docs/design/validation.json').write_text(output)
    print(output)
    # Contract failures raise above; a bounds-rule failure is reported and fails the run.
    sys.exit(1 if any(r.get('v2', {}).get('boundsRule') == 'fail' for r in report.values()) else 0)
