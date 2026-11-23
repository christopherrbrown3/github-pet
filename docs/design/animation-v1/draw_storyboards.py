"""Draws docs/design/animation-v1/storyboards.svg: rough key-pose thumbnails for animation v1 (#138).

The figure is a neutral stand-in bean, not Mona or Little Chris: it only shows pose, props, timing
and the layout limits (dashed union top at canvas y 20, shaded label/keep-out band above y 64 where
no FX may draw). Codex draws the real frames from the asset list in animation-v1.md.
"""
import math
import pathlib

CELL = 96          # thumbnail side in px; the 256-unit canvas is scaled to fit
S = CELL / 256
GAP_X, GAP_Y, LABEL_W, TITLE_H = 10, 34, 170, 30

INK, BODY, FACE = '#2b2b33', '#8a7fd1', '#f4efe6'
HAT, STEEL, MIST, ENV, SPARK = '#c8372d', '#9aa3ad', '#cfe6f5', '#f7f1d9', '#f2b632'


def u(v):
    return round(v * S, 2)


def figure(x0, y0, pose):
    """One thumbnail; pose keys: eyes, mouth, arms (l, r angles, deg from down), lean, squash,
    props (set), fx (set), head_dy, dz (dozing slump)."""
    g = []
    cx, ground = 128, 232
    sq = pose.get('squash', 1.0)
    h = 150 * sq
    w = 120 / max(sq, 0.8) if sq < 1 else 120
    top = ground - h + pose.get('head_dy', 0)
    lean = pose.get('lean', 0)
    g.append(f'<g transform="translate({x0},{y0})">')
    g.append(f'<rect width="{CELL}" height="{CELL}" rx="6" fill="#ffffff" stroke="#d0d0d8"/>')
    g.append(f'<rect width="{CELL}" height="{u(64)}" rx="6" fill="#f1eefc"/>')
    g.append(f'<line x1="0" x2="{CELL}" y1="{u(20)}" y2="{u(20)}" stroke="#b9b2e6" stroke-dasharray="2 2"/>')
    g.append(f'<line x1="0" x2="{CELL}" y1="{u(232)}" y2="{u(232)}" stroke="#d0d0d8"/>')
    for fx in pose.get('fx', ()):
        g.append(effect(fx))
    g.append(f'<g transform="rotate({lean} {u(128)} {u(232)})">')
    # arms behind body ends
    for side, ang in (('l', pose.get('arms', (20, 20))[0]), ('r', pose.get('arms', (20, 20))[1])):
        sx = cx - w / 2 + 8 if side == 'l' else cx + w / 2 - 8
        sy = top + h * 0.55
        a = math.radians(ang)
        dx = -math.sin(a) * 46 if side == 'l' else math.sin(a) * 46
        dy = math.cos(a) * 46
        g.append(f'<line x1="{u(sx)}" y1="{u(sy)}" x2="{u(sx + dx)}" y2="{u(sy + dy)}" stroke="{INK}" '
                 f'stroke-width="{u(14)}" stroke-linecap="round"/>')
    g.append(f'<rect x="{u(cx - w / 2)}" y="{u(top)}" width="{u(w)}" height="{u(h)}" rx="{u(46)}" '
             f'fill="{BODY}" stroke="{INK}" stroke-width="1.2"/>')
    g.append(f'<ellipse cx="{u(cx)}" cy="{u(top + 52)}" rx="{u(40)}" ry="{u(28)}" fill="{FACE}"/>')
    g.append(eyes(cx, top + 48, pose.get('eyes', 'open')))
    g.append(mouth(cx, top + 66, pose.get('mouth', 'smile')))
    for prop in pose.get('props', ()):
        g.append(prop_svg(prop, cx, top, w, h))
    g.append('</g>')
    g.append('</g>')
    return '\n'.join(g)


def eyes(cx, ey, kind):
    out = []
    for ex in (cx - 16, cx + 16):
        if kind in ('closed', 'squeeze'):
            out.append(f'<path d="M{u(ex - 6)} {u(ey)} q{u(6)} {u(5 if kind == "closed" else -5)} {u(12)} 0" '
                       f'stroke="{INK}" fill="none" stroke-width="1.2"/>')
        elif kind == 'swirl':
            out.append(f'<circle cx="{u(ex)}" cy="{u(ey)}" r="{u(7)}" fill="none" stroke="{INK}" stroke-dasharray="2 1.2"/>')
        else:
            off = {'left': (-4, 0), 'right': (4, 0), 'up': (0, -4), 'down-left': (-4, 3)}.get(kind, (0, 0))
            r = 8 if kind == 'wide' else 6
            out.append(f'<circle cx="{u(ex + off[0])}" cy="{u(ey + off[1])}" r="{u(r)}" fill="{INK}"/>')
    return ''.join(out)


def mouth(cx, my, kind):
    if kind == 'o':
        return f'<circle cx="{u(cx)}" cy="{u(my)}" r="{u(5)}" fill="{INK}"/>'
    if kind == 'yawn':
        return f'<ellipse cx="{u(cx)}" cy="{u(my)}" rx="{u(7)}" ry="{u(9)}" fill="{INK}"/>'
    if kind == 'flat':
        return f'<line x1="{u(cx - 7)}" x2="{u(cx + 7)}" y1="{u(my)}" y2="{u(my)}" stroke="{INK}" stroke-width="1.2"/>'
    curve = 9 if kind == 'grin' else 5
    return (f'<path d="M{u(cx - 9)} {u(my - 2)} q{u(9)} {u(curve)} {u(18)} 0" stroke="{INK}" fill="none" '
            f'stroke-width="1.2"/>')


def prop_svg(prop, cx, top, w, h):
    if prop == 'hat':
        return (f'<path d="M{u(cx - 50)} {u(top + 30)} q{u(50)} {u(-40)} {u(100)} 0 z" fill="{HAT}" stroke="{INK}"/>'
                f'<rect x="{u(cx - 62)}" y="{u(top + 26)}" width="{u(124)}" height="{u(8)}" rx="{u(4)}" fill="{HAT}" stroke="{INK}"/>'
                f'<path d="M{u(cx)} {u(top + 4)} l{u(8)} {u(8)} l{u(-8)} {u(10)} l{u(-8)} {u(-10)} z" fill="{ENV}"/>')
    if prop == 'hat-hand':
        return (f'<path d="M{u(cx - 70)} {u(top + 100)} q{u(30)} {u(-30)} {u(60)} 0 z" fill="{HAT}" stroke="{INK}"/>')
    if prop == 'hat-lift':
        return (f'<path d="M{u(cx - 50)} {u(top + 40)} q{u(50)} {u(-36)} {u(100)} 0 z" fill="{HAT}" stroke="{INK}" '
                f'transform="rotate(-14 {u(cx)} {u(top + 40)})"/>')
    if prop in ('ext', 'ext-aim'):
        bx, by = cx - 70, top + 96
        tilt = 30 if prop == 'ext-aim' else 0
        return (f'<g transform="rotate({tilt} {u(bx + 10)} {u(by + 24)})">'
                f'<rect x="{u(bx)}" y="{u(by)}" width="{u(22)}" height="{u(50)}" rx="{u(6)}" fill="{HAT}" stroke="{INK}"/>'
                f'<path d="M{u(bx + 11)} {u(by)} q{u(-20)} {u(-6)} {u(-26)} {u(14)}" stroke="{INK}" fill="none" stroke-width="1.2"/></g>')
    if prop == 'env':
        return (f'<rect x="{u(cx - 96)}" y="{u(top + 22)}" width="{u(44)}" height="{u(30)}" fill="{ENV}" stroke="{INK}"/>'
                f'<path d="M{u(cx - 96)} {u(top + 22)} l{u(22)} {u(16)} l{u(22)} {u(-16)}" stroke="{INK}" fill="none"/>')
    if prop == 'env-low':
        return (f'<rect x="{u(cx - 22)}" y="{u(top + 96)}" width="{u(44)}" height="{u(30)}" fill="{ENV}" stroke="{INK}"/>'
                f'<path d="M{u(cx - 22)} {u(top + 96)} l{u(22)} {u(16)} l{u(22)} {u(-16)}" stroke="{INK}" fill="none"/>')
    if prop == 'phone':
        return f'<rect x="{u(cx - 14)}" y="{u(top + 92)}" width="{u(24)}" height="{u(36)}" rx="{u(4)}" fill="{INK}"/>'
    if prop == 'thumb':
        return f'<circle cx="{u(cx + 74)}" cy="{u(top + 50)}" r="{u(10)}" fill="{FACE}" stroke="{INK}"/>'
    return ''


def effect(fx):
    if fx == 'mist':
        return ''.join(f'<circle cx="{u(x)}" cy="{u(y)}" r="{u(r)}" fill="{MIST}" stroke="#9cc3dc" stroke-width=".6"/>'
                       for x, y, r in ((40, 214, 12), (22, 226, 9), (56, 230, 8), (14, 206, 7)))
    if fx == 'smoke':
        return ''.join(f'<circle cx="{u(x)}" cy="{u(y)}" r="{u(r)}" fill="#d9d9de" opacity=".8"/>'
                       for x, y, r in ((30, 150, 14), (226, 160, 12), (20, 110, 10)))
    if fx == 'flames':
        return ''.join(f'<path d="M{u(x - 10)} {u(240)} q{u(10)} {u(-30 * s)} {u(10)} {u(-44 * s)} '
                       f'q{u(4)} {u(24 * s)} {u(10)} {u(44 * s)} z" fill="#f08a2c" opacity=".85"/>'
                       for x, s in ((24, 1), (44, .7), (214, .9), (236, .6)))
    if fx == 'flames-low':
        return ''.join(f'<path d="M{u(x - 8)} {u(240)} q{u(8)} {u(-12)} {u(8)} {u(-16)} '
                       f'q{u(3)} {u(8)} {u(8)} {u(16)} z" fill="#f08a2c" opacity=".6"/>'
                       for x in (24, 214))
    if fx == 'siren':
        return f'<rect x="{u(12)}" y="{u(204)}" width="{u(30)}" height="{u(28)}" rx="{u(8)}" fill="#e0453a"/>'
    if fx == 'sparkle':
        return ''.join(f'<path d="M{u(x)} {u(y - 9)} l{u(3)} {u(6)} l{u(6)} {u(3)} l{u(-6)} {u(3)} l{u(-3)} {u(6)} '
                       f'l{u(-3)} {u(-6)} l{u(-6)} {u(-3)} l{u(6)} {u(-3)} z" fill="{SPARK}"/>'
                       for x, y in ((210, 90), (36, 120), (222, 150)))
    if fx == 'spark1':
        return f'<path d="M{u(214)} {u(80)} l{u(4)} {u(8)} l{u(8)} {u(4)} l{u(-8)} {u(4)} l{u(-4)} {u(8)} l{u(-4)} {u(-8)} l{u(-8)} {u(-4)} l{u(8)} {u(-4)} z" fill="{SPARK}"/>'
    if fx == 'z':
        return ''.join(f'<text x="{u(x)}" y="{u(y)}" font-size="{u(s)}" font-family="Helvetica" font-weight="700" '
                       f'fill="#7b74b8">z</text>' for x, y, s in ((24, 150, 26), (38, 110, 34)))
    if fx == 'motion':
        return ''.join(f'<line x1="{u(x)}" x2="{u(x + 22)}" y1="{u(y)}" y2="{u(y)}" stroke="#b0b0bc"/>'
                       for x, y in ((16, 120), (8, 150), (18, 180)))
    return ''


B = {}  # shared poses
IDLE = dict(eyes='open', mouth='smile', arms=(18, 18))
HAT_IDLE = dict(IDLE, props={'hat'})

ROWS = [
    ('incident-start', 'hat on (≈1.9 s)', [
        (dict(eyes='down-left', mouth='o', arms=(18, 18), fx={'siren'}), '00 · 250'),
        (dict(eyes='wide', mouth='flat', arms=(40, 18), props={'hat-hand'}, fx={'siren'}), '01 · 300'),
        (dict(eyes='up', mouth='flat', arms=(150, 150), props={'hat-lift'}, fx={'siren'}), '02 · 300'),
        (dict(eyes='squeeze', mouth='grin', arms=(140, 140), props={'hat'}, fx={'siren'}), '03 · 250'),
        (dict(eyes='open', mouth='flat', arms=(60, 60), head_dy=4, props={'hat'}, fx={'siren'}), '04 · 500'),
        (dict(HAT_IDLE, fx={'siren'}), '05 · 300 =idle+hat'),
    ]),
    ('incident-end', 'extinguisher, phew (≈2.7 s)', [
        (dict(eyes='open', mouth='grin', arms=(30, 18), props={'hat', 'ext'}, fx={'flames'}), '00 · 250'),
        (dict(eyes='down-left', mouth='flat', arms=(50, 30), props={'hat', 'ext-aim'}, fx={'flames'}), '01 · 250'),
        (dict(eyes='down-left', mouth='grin', arms=(60, 40), lean=2, props={'hat', 'ext-aim'}, fx={'flames', 'mist'}), '02 · 300 (×2)'),
        (dict(eyes='down-left', mouth='grin', arms=(40, 40), props={'hat', 'ext-aim'}, fx={'flames-low', 'mist', 'smoke'}), '03 · 300'),
        (dict(eyes='down-left', mouth='smile', arms=(18, 18), props={'hat', 'ext'}, fx={'smoke'}), '05 · 300'),
        (dict(eyes='closed', mouth='grin', arms=(150, 30), props={'hat-hand'}), '06 · 700 phew'),
        (dict(IDLE), '07 · 300 =idle-00'),
    ]),
    ('new-item', 'envelope (1.9 s)', [
        (dict(eyes='wide', mouth='o', arms=(18, 18)), '00 · 200'),
        (dict(eyes='wide', mouth='smile', arms=(60, 40), squash=.92, props={'env-low'}), '01 · 200'),
        (dict(eyes='open', mouth='grin', arms=(160, 30), props={'env'}), '02 · 350'),
        (dict(eyes='open', mouth='grin', arms=(150, 30), lean=-2, props={'env'}), '03 · 350'),
        (dict(eyes='open', mouth='smile', arms=(60, 60), props={'env-low'}), '04 · 800'),
    ]),
    ('item-cleared', 'thumbs-up (1.2 s)', [
        (dict(eyes='down-left', mouth='smile', arms=(18, 18)), '00 · 200'),
        (dict(eyes='open', mouth='grin', arms=(18, 140), props={'thumb'}, fx={'spark1'}), '01 · 300'),
        (dict(eyes='squeeze', mouth='grin', arms=(18, 140), props={'thumb'}), '02 · 400 wink'),
        (dict(IDLE), '03 · 300 =idle-00'),
    ]),
    ('inbox-zero', 'happy dance (2.0 s)', [
        (dict(eyes='wide', mouth='grin', arms=(30, 30)), '00 · 250'),
        (dict(eyes='closed', mouth='grin', arms=(140, 30), lean=-4), '01 · 300 (×2)'),
        (dict(eyes='closed', mouth='grin', arms=(30, 140), lean=4), '02 · 300'),
        (dict(eyes='closed', mouth='grin', arms=(150, 150), fx={'sparkle'}), '04 · 450 yay'),
        (dict(eyes='closed', mouth='smile', arms=(100, 100)), '05 · 400'),
    ]),
    ('drag · drop', 'held loop, then landing', [
        (dict(eyes='wide', mouth='o', arms=(8, 8), squash=1.06, fx={'motion'}), 'drag-00 · 400'),
        (dict(eyes='wide', mouth='grin', arms=(-6, 22), squash=1.06, lean=-5, fx={'motion'}), 'drag-01 · 400 ±5°'),
        (dict(eyes='squeeze', mouth='grin', arms=(70, 70), squash=.86), 'drop-00 · 200'),
        (dict(eyes='open', mouth='grin', arms=(30, 30), squash=1.03), 'drop-01 · 250'),
    ]),
    ('poke · dizzy', 'click reactions', [
        (dict(eyes='squeeze', mouth='grin', arms=(40, 18), lean=3), 'poke-00 · 250'),
        (dict(eyes='squeeze', mouth='o', arms=(18, 120)), 'poke-01 · 300'),
        (dict(eyes='swirl', mouth='o', arms=(40, 40)), 'dizzy-00 · 300'),
        (dict(eyes='swirl', mouth='flat', arms=(60, 20), lean=-5), 'dizzy-01 · 300'),
        (dict(eyes='swirl', mouth='flat', arms=(20, 60), lean=5), 'dizzy-02 · 300'),
        (dict(eyes='closed', mouth='smile', arms=(30, 30)), 'dizzy-03 · 400'),
    ]),
    ('idle variants', 'look · stretch · fidget', [
        (dict(eyes='left', mouth='smile'), 'look-00 · 500'),
        (dict(eyes='right', mouth='smile'), 'look-01 · 500'),
        (dict(eyes='up', mouth='o'), 'look-02 · 600'),
        (dict(eyes='closed', mouth='yawn', arms=(30, 30)), 'stretch-00 · 400'),
        (dict(eyes='closed', mouth='yawn', arms=(95, 95)), 'stretch-01 · 600'),
        (dict(eyes='down-left', mouth='smile', arms=(50, 50), props={'phone'}), 'fidget-01 · 700'),
    ]),
    ('doze', 'held loop', [
        (dict(eyes='closed', mouth='smile', arms=(10, 10), squash=.95, head_dy=6, fx={'z'}), 'doze-00 · 1200'),
        (dict(eyes='closed', mouth='o', arms=(10, 10), squash=.93, head_dy=8, fx={'z'}), 'doze-01 · 1200'),
    ]),
]


def main():
    cols = max(len(frames) for _, _, frames in ROWS)
    width = LABEL_W + cols * (CELL + GAP_X) + 10
    height = TITLE_H + len(ROWS) * (CELL + GAP_Y) + 40
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
           f'font-family="-apple-system, Helvetica, sans-serif">',
           f'<rect width="{width}" height="{height}" fill="#fafafa"/>',
           f'<text x="10" y="20" font-size="14" font-weight="700" fill="{INK}">GitHub Pet animation v1 · rough key poses '
           f'(stand-in figure, not final art)</text>']
    for r, (name, sub, frames) in enumerate(ROWS):
        y = TITLE_H + r * (CELL + GAP_Y)
        out.append(f'<text x="10" y="{y + 36}" font-size="13" font-weight="700" fill="{INK}">{name}</text>')
        out.append(f'<text x="10" y="{y + 54}" font-size="11" fill="#66667a">{sub}</text>')
        for c, (pose, caption) in enumerate(frames):
            x = LABEL_W + c * (CELL + GAP_X)
            out.append(figure(x, y, pose))
            out.append(f'<text x="{x + CELL / 2}" y="{y + CELL + 14}" font-size="10" text-anchor="middle" '
                       f'fill="#44445a">{caption}</text>')
    ly = height - 16
    out.append(f'<text x="10" y="{ly}" font-size="10" fill="#66667a">Shaded band: label lane / FX keep-out (canvas y &lt; 64). '
               f'Dashed line: skin union top (y 20), no frame or hat pixel above it. Bottom line: ground y 232. '
               f'Captions: frame · ms.</text>')
    out.append('</svg>')
    path = pathlib.Path(__file__).with_name('storyboards.svg')
    path.write_text('\n'.join(out) + '\n')
    print(path)


if __name__ == '__main__':
    main()
