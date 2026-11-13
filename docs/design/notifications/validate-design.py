"""Checks design geometry/timing and unchanged source art; no runtime tests."""
from pathlib import Path
import hashlib
import json
import math
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
from png_rgba import bounds, read_png

pack = ROOT / 'assets/mascots/mona-pet-v1'
manifest = json.loads((pack / 'manifest.json').read_text())
for name, digest in manifest['frameSha256'].items():
    assert hashlib.sha256((pack / name).read_bytes()).hexdigest() == digest
plan = json.loads((HERE / 'attention-storyboard.json').read_text())
assert plan['durationMs'] == sum(s['durationMs'] for s in plan['steps']) == 1900
assert plan['loop'] is False and plan['staticFallback'] == {'frame': 'attention-03.png', 'angleDegrees': 0}
elapsed = 0
for step in plan['steps']:
    assert step['startMs'] == elapsed and 125 <= step['durationMs'] <= 2000
    elapsed += step['durationMs']
    assert abs(step['angleDegrees']) <= 5
assert plan['steps'][-1]['durationMs'] == 600 and plan['steps'][-1]['angleDegrees'] == 0

# Conservative alpha bounding rectangles, rotated over the full allowed angular
# interval; actual visible pixels are contained in these rectangles.
rotated = []
for frame in sorted({s['frame'] for s in plan['steps']}):
    w, h, pixels = read_png(pack / 'frames' / frame)
    assert (w, h) == (256, 256)
    box = bounds(pixels, w, lambda r, g, b, a: a > 0)
    points = []
    for a in range(-50, 51):
        theta = math.radians(a / 10)
        for x in [box[0], box[2]]:
            for y in [box[1], box[3]]:
                points.append((128 + (x - 128) * math.cos(theta) - (y - 232) * math.sin(theta),
                               232 + (x - 128) * math.sin(theta) + (y - 232) * math.cos(theta)))
    extent = [min(x for x,y in points), min(y for x,y in points), max(x for x,y in points), max(y for x,y in points)]
    assert extent[0] >= 0 and extent[1] >= 0 and extent[2] <= 256 and extent[3] <= 256
    rotated.append({'frame': frame, 'conservativeBoundsAcrossAngles': [round(v, 2) for v in extent]})

measurements = json.loads((HERE / 'native-measurements.json').read_text())['measurements']
assert len(measurements) == 12
assert {m['label'] for m in measurements} == {'2','2+','?','99+'}
assert all(m['gap'] >= m['minimumGap'] for m in measurements)
html = (HERE / 'preview.html').read_text()
embedded = json.loads(re.search(r'<script type="application/json" id="plan">(.*?)</script>', html).group(1))
assert embedded == plan
for filename in ['badges-light.png','badges-dark.png','attention-keyposes.png']:
    blob = (HERE / filename).read_bytes()
    assert blob[:8] == b'\x89PNG\r\n\x1a\n'

report = {'result': 'pass', 'sourceFrameHashesVerified': len(manifest['frameSha256']),
          'timelineDurationMs': elapsed, 'loop': False, 'staticFallback': plan['staticFallback'],
          'badgeLabelsMeasured': len(measurements), 'minimumMeasuredLabelGapPt': min(m['gap'] for m in measurements),
          'rotatedFrameBounds': rotated,
          'limitations': ['Standalone AppKit design compositions and browser preview; not production native UI acceptance.',
                          'Source eligibility, quiet/snooze, system settings, hover edges and live display scaling require later runtime QA.']}
(HERE / 'design-validation.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
