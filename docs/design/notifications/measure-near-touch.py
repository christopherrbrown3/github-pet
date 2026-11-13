"""Sample existing art alpha contours against real capsule shapes; no art generation.

Inputs are the original v1 PNGs and prior AppKit SF measurements. Output is a
design estimate, not a substitute for native compositing/edge-clamp tests.
"""
from pathlib import Path
import json
import math
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
from png_rgba import read_png

measurements = json.loads((HERE / 'native-measurements.json').read_text())['measurements']
source = ROOT / 'assets/mascots/mona-pet-v1/frames'
frames = {}
for path in sorted(source.glob('*.png')):
    w, h, rgba = read_png(path)
    assert (w, h) == (256, 256)
    mask = [rgba[i + 3] > 0 for i in range(0, len(rgba), 4)]
    points = set()
    # The capsule is above the head; lower art cannot be the nearest point.
    # Check exposed pixel-square edges at quarter-source-pixel intervals.
    for y in range(1, 90):
        for x in range(1, w - 1):
            if not mask[y * w + x]:
                continue
            for neighbor, edge in [(-1, 'left'), (1, 'right'), (-w, 'top'), (w, 'bottom')]:
                if mask[y * w + x + neighbor]:
                    continue
                for i in range(5):
                    t = i / 4
                    points.add((x + (0 if edge == 'left' else 1 if edge == 'right' else t),
                                y + (0 if edge == 'top' else 1 if edge == 'bottom' else t)))
    frames[path.stem] = sorted(points)

result = {'source': 'mona-pet-v1; nonzero alpha pixel edges', 'angleStepDegrees': 0.1,
          'targetVisibleGapPt': 1, 'rasterReservePt': 0.25,
          'limitations': ['Source-contour estimate; native 1x/2x compositing and runtime placement remain unverified.',
                          'Global fixed envelope means some individual upright poses can sit farther than the closest pose.'],
          'scales': []}
for size, panel_width, count_height, demo_height, inset in [(64,96,20,16,4),(128,128,28,20,6),(256,256,40,24,8)]:
    values = {item['label']: item for item in measurements if item['size'] == size}
    count_slot_width = max(v['countWidth'] for v in values.values())
    count_left = panel_width - inset - count_slot_width
    demo_width = values['99+']['demoWidth']
    factor = size / 256
    art_x = (panel_width - size) / 2
    demo_top = count_height - demo_height - 0.5
    capsules = [('DEMO', inset, demo_width, demo_height, demo_top)] + [
        (label, count_left, values[label]['countWidth'], count_height, 0)
        for label in ['2', '2+', '?', '99+']]
    required = {name: -1e9 for name, *_ in capsules}
    by_state = {name: {'idle': -1e9, 'urgent': -1e9, 'attention-static': -1e9, 'attention-sway': -1e9} for name, *_ in capsules}
    for frame, points in frames.items():
        modes = ['idle'] if frame.startswith('idle') else ['urgent'] if frame.startswith('urgent') else ['attention-sway'] + (['attention-static'] if frame == 'attention-03' else [])
        for mode in modes:
            angles = [i / 10 for i in range(-50, 51)] if mode == 'attention-sway' else [0]
            for angle in angles:
                radians = math.radians(angle)
                cosine, sine = math.cos(radians), math.sin(radians)
                # Maximum boundary interpolation error: 0.125 source px edge
                # sampling plus <0.21 source px between angular samples.
                sampling_margin = (0.335 if mode == 'attention-sway' else 0.125) * factor
                for sx, sy in points:
                    dx, dy = sx - 128, sy - 232
                    x = art_x + (128 + dx * cosine - dy * sine) * factor
                    y = (232 + dx * sine + dy * cosine) * factor
                    for name, left, width, height, top in capsules:
                        radius = height / 2
                        center = min(max(x, left + radius), left + width - radius)
                        d = abs(x - center)
                        # Minkowski expansion implements the 1 pt target and a
                        # 0.25 pt compositing reserve, plus sampling margin.
                        expanded = radius + 1.25 + sampling_margin
                        if d <= expanded:
                            lower = top + radius + math.sqrt(max(0, expanded * expanded - d * d))
                            by_state[name][mode] = max(by_state[name][mode], lower - y)
                            required[name] = max(required[name], lower - y)
    lane = math.ceil(max(required.values()) * 4) / 4
    state_lanes = {state: math.ceil(max(states[state] for states in by_state.values()) * 4) / 4
                   for state in ['idle', 'urgent', 'attention-static', 'attention-sway']}
    # Independently sample actual nearest contour-to-capsule distances for
    # each pose. These are source-geometry measurements, not native captures.
    sampled = {label: {state: [] for state in state_lanes} for label in ['2+', '99+']}
    for frame, points in frames.items():
        modes = ['idle'] if frame.startswith('idle') else ['urgent'] if frame.startswith('urgent') else ['attention-sway'] + (['attention-static'] if frame == 'attention-03' else [])
        for mode in modes:
            angles = [i / 2 for i in range(-10, 11)] if mode == 'attention-sway' else [0]
            for angle in angles:
                radians = math.radians(angle)
                cosine, sine = math.cos(radians), math.sin(radians)
                nearest = {'2+': float('inf'), '99+': float('inf')}
                for sx, sy in points:
                    dx, dy = sx - 128, sy - 232
                    x = art_x + (128 + dx * cosine - dy * sine) * factor
                    y = state_lanes[mode] + (232 + dx * sine + dy * cosine) * factor
                    for label in nearest:
                        radius = count_height / 2
                        center = min(max(x, count_left + radius), count_left + values[label]['countWidth'] - radius)
                        distance = math.hypot(x - center, y - radius) - radius
                        nearest[label] = min(nearest[label], distance)
                for label, gap in nearest.items():
                    assert gap >= 1, (size, frame, mode, angle, label, gap)
                    sampled[label][mode].append(gap)
    sampled_ranges = {label: {state: [round(min(gaps), 3), round(max(gaps), 3)]
                              for state, gaps in states.items()} for label, states in sampled.items()}
    assert lane >= 0
    assert count_left - (inset + demo_width) >= {64:6, 128:8, 256:12}[size]
    result['scales'].append({'artSidePt': size, 'panelWidthPt': panel_width,
        'laneHeightPt': lane, 'panelHeightPt': size + lane, 'stateLaneTargetsPt': state_lanes,
        'countSlotLeftPt': count_left,
        'countSlotWidthPt': count_slot_width, 'demoLeftPt': inset, 'demoTopPt': demo_top,
        'sampledVisibleCountGapRangePt': sampled_ranges,
        'requiredLaneByLabelPt': {name: round(value, 3) for name, value in required.items()},
        'requiredLaneByLabelAndStatePt': {name: {k: round(v, 3) for k,v in states.items()} for name,states in by_state.items()}})
out = json.dumps(result, indent=2) + '\n'
(HERE / 'near-touch-measurements.json').write_text(out)
print(out)
