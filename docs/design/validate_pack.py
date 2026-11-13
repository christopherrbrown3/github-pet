#!/usr/bin/env python3
"""Validate real pack files against the developer-agreed v1 contract."""
from pathlib import Path
import hashlib
import json
import sys
from png_rgba import bounds, read_png, sha256_png

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / 'assets/mascots/mona-pet-v1'


def check_pack(pack):
    manifest = json.loads((pack / 'manifest.json').read_text())
    assert manifest['schemaVersion'] == 1
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
        assert clip['staticFallback'] in clip['frames']
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
    for relative, expected in packing['sourceSha256'].items():
        assert sha256_png(resolve(relative)) == expected
    for sheet in packing['sheets'].values():
        path = resolve(sheet['path'])
        width, height, _ = read_png(path)
        assert [width, height] == sheet['size'] == [1024, 256]
        assert sha256_png(path) == sheet['sha256']
    return {'result': 'pass', 'contract': 'developer v1', 'canvas': [256, 256], 'anchor': [128, 232],
            'states': results, 'decodedRuntimeFrameBytes': decoded,
            'manifestSha256': hashlib.sha256((pack / 'manifest.json').read_bytes()).hexdigest(),
            'limitations': ['Source sheets are generated; minor contour variation remains between poses.',
                            'Browser design review is not native app, VoiceOver, or physical display verification.']}


if __name__ == '__main__':
    report = check_pack(PACK)
    output = json.dumps(report, indent=2) + '\n'
    if '--report' in sys.argv:
        (ROOT / 'docs/design/validation.json').write_text(output)
    print(output)
