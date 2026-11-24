# Animation v2: cutout rig (#138)

The frame-based v2 clips (PR #169) were rejected. They were choppy (3 to 5 poses held 200 to 800 ms with hard cuts), incoherent (every generated pose drifted in head size, helmet size and proportions), and the flat front-facing hat never looked worn on a 3/4 head. This doc replaces section 5 of [animation-v1.md](animation-v1.md) (the per-frame asset list) with a **cutout rig**: each skin is a few painted parts generated once, moved by the app at 30 to 60 fps with eased transforms, squash and stretch, overlap and secondary motion.

What carries over from v1 unchanged: the clip set and triggers (section 1), priorities, gating, "never misrepresent state", ambient scheduling and cooldowns (section 2), the FX sprites, the bounds rule and the layout contract (lane, hover and the count never move because of animation). What changes: how a pose is made (transforms of parts, not a new painting), clip timing (continuous curves, not held frames) and the pack format (schema v3).

Why this fixes each complaint:

| Complaint | Cause in frame packs | Rig answer |
|---|---|---|
| Choppy | 3 to 5 poses, 200 to 800 ms each, hard cuts | Every bone is evaluated every frame from eased curves at 30 to 60 fps. Nothing is held unless the motion says so. |
| Incoherent | Each pose was a fresh generation, so head, helmet and proportions drift | Each part is painted once. Every pose is the same pixels moved, so head size and proportions cannot drift. |
| Hat never worn | A front-view overlay pasted on heads drawn at other angles | The rig head never changes its view. The helmet is painted for that head, split into a back brim (behind the head) and a front shell (in front), and parented to the head bone, so it tilts and squashes with the head. |

## 1. Conventions

- **Canvas units.** Positions are in the existing 256 × 256 canvas, y down, ground anchor `[128, 232]`. Angles are degrees, positive clockwise (screen y down). "Left" and "right" are the viewer's.
- **Part images are authored at 2×** (2 px per canvas unit, so a 150-unit head is a 300 px image). The mascot draws at up to 256 pt on a 2× display, and rotated parts need the extra pixels to stay crisp. Sizes below give units and pixels.
- **Rest pose = idle-00 scaled 0.96 about the anchor.** The rig rest pose matches today's `idle-00` silhouette, shrunk 4% (2.5 pt at 64 pt). That buys about 9 units of headroom under the y 20 limit for perk-ups, hops and the helmet, so the union (Mona x 47 to 217, Little Chris x 62 to 205, y ≥ 20) and therefore the lane, hover and badge slot stay exactly as today. Coordinates below are idle-00 coordinates (before the 0.96); the root bone applies the scale.
- **Every number marked ≈ is a target for generation and is measured at assembly** (section 6.4), within ±4 units.

## 2. Rig per skin

### 2.1 Joint rules (both skins)

Rotation must never open a gap or show a hard edge at a joint.

1. **Round joint caps.** The end of a child part at its pivot is a filled half-disc centred on the pivot, with radius equal to the limb's half-width there. Rotating about the pivot sweeps the cap inside its own circle, so the silhouette at the joint never changes.
2. **Extension under the neighbour.** Each child extends past its pivot, under its parent (or under whatever covers the joint in draw order), by at least `w · sin(θmax) + 4` units, where `w` is the half-width at the joint and `θmax` the largest rotation any clip uses. The table values below already satisfy this for the listed ranges. The validator rejects keys that exceed a joint's range.
3. **Hidden seams.** Joints sit where the parent covers them: the head covers the top of the body and the tentacle roots, the hoodie cuffs cover the wrists, the hood covers the neck. A part's extension is painted in the part's flat local colour with the same contour treatment, so if a tiny sliver shows it reads as the part, not a hole.
4. **No contour across the joint.** Outline strokes stop at the point where the neighbour covers the part, so no dark line shows through when the joint bends.
5. **Lighting stays put.** Light is from the upper left on every part. Parts rotate at most ±40° (tentacle tips ±70°, which are nearly uniform black), so the baked lighting never reads as upside-down.

### 2.2 Mona-inspired pet

Part pivots and rest positions are in idle-00 canvas units. Image size is the part's bounding box plus extensions, authored at 2×.

| Part | Parent bone | Pivot (canvas) | Rest box (canvas, ≈) | Image (≈ units → px) | Extension rule | Rotation range |
|---|---|---|---|---|---|---|
| `root` (bone only) | — | `[128, 232]` | — | — | — | ±6° (lean), scale 0.85 to 1.12 |
| `body` | root | `[128, 196]` | x 72 to 184, y 118 to 214 | 112 × 96 → 224 × 192 | Extends up to y 118, 22 units under the head; bottom extends 10 units under the legs | ±6° |
| `leg-l` | body | `[92, 196]` | x 60 to 112, y 186 to 231 | 56 × 52 → 112 × 104 | Root extends 14 units up under the body, round cap | ±18° |
| `leg-c` | body | `[128, 200]` | x 106 to 150, y 190 to 231 | 48 × 48 → 96 × 96 | Same | ±14° |
| `leg-r` | body | `[164, 196]` | x 144 to 196, y 186 to 231 | 56 × 52 → 112 × 104 | Same | ±18° |
| `arm-l` (tentacle base) | body | `[84, 160]` | x 56 to 96, y 150 to 200 | 44 × 56 → 88 × 112 | Root extends 16 units under the body and head | −120° to +30° |
| `arm-l-tip` | arm-l | `[64, 196]` (≈ end of base) | x 50 to 80, y 186 to 214 | 34 × 34 → 68 × 68 | Round cap at the pivot, 10 units back into the base | ±70° |
| `arm-r` | body | `[172, 156]` | x 164 to 206, y 140 to 176 | 46 × 40 → 92 × 80 | Root extends 16 units under the body and head | −30° to +120° |
| `arm-r-tip` | arm-r | `[200, 150]` | x 192 to 212, y 132 to 158 | 24 × 30 → 48 × 60 | Round cap, 10 units back | ±70° |
| `head` | body | `[128, 136]` (neck) | x 52 to 202, y 22 to 140 | 156 × 130 → 312 × 260 | Neck extends 12 units below y 140 over the body; ears painted on | ±12°, scale 0.9 to 1.1 |

That is 10 painted parts plus the root. The two arm tentacles are the ones that gesture (hold props, wave, thumbs-up loop). The three front legs sway and squash. Any tentacles behind them are painted into `body` and do not move.

**Tip variants** (same pivot, same cap, swapped by the clip like a face layer): `arm-l-tip` and `arm-r-tip` each come as `straight` (rest), `curl` (tip rolled into a neat loop: Mona's "thumbs-up" and fidget curl) and `grip` (tip wrapped around nothing, a C shape that a prop sits inside).

**Draw order** (back to front): `leg-l`, `leg-r`, `leg-c`, `body`, `arm-l`, `arm-l-tip`, `arm-r`, `arm-r-tip`, `helmet-back`, `head`, face layers, `helmet-front`, then props held by a tip (drawn after their tip, with the `grip` tip variant's front lobe drawn again on top so the tentacle wraps the prop: the `grip` variant is two images, `grip-back` and `grip-front`). A clip may raise an arm above the head for one segment with `"drawOrder": {"arm-l": "front"}` (used when an arm crosses in front of the body at chest height; it never crosses the face).

**Painted vs swapped.** Painted into `head`: the black hood with cat ears, the cream face plate **with no eyes and no mouth**, whiskers, the soft gray highlights and the dark contour. Swapped: eyes, mouth, optional blush (section 3).

### 2.3 Little Chris

| Part | Parent bone | Pivot (canvas) | Rest box (≈) | Image (≈ units → px) | Extension rule | Rotation range |
|---|---|---|---|---|---|---|
| `root` (bone only) | — | `[128, 232]` | — | — | — | ±6°, scale 0.85 to 1.12 |
| `leg-l` | root | `[114, 190]` (hip) | x 96 to 128, y 184 to 231 | 34 × 54 → 68 × 108 | Top extends 12 units up under the hoodie hem, round cap; sneaker painted on | ±12° |
| `leg-r` | root | `[142, 190]` | x 128 to 160, y 184 to 231 | 34 × 54 → 68 × 108 | Same | ±12° |
| `torso` | root | `[128, 188]` (hips) | x 92 to 164, y 108 to 194 | 76 × 92 → 152 × 184 | Hood rim extends up to y 108, 10 units under the head; hem covers the leg tops | ±8°, scale 0.9 to 1.1 |
| `arm-l` (upper sleeve) | torso | `[100, 126]` (shoulder) | x 84 to 108, y 118 to 160 | 28 × 48 → 56 × 96 | Shoulder cap, extends 10 units in under the torso | −150° to +40° |
| `fore-l` (lower sleeve and cuff) | arm-l | `[94, 156]` (elbow) | x 82 to 104, y 150 to 182 | 26 × 38 → 52 × 76 | Elbow cap, 10 units back into the upper sleeve | 0° to +130° (bends inward) |
| `hand-l` | fore-l | `[93, 178]` (wrist) | x 84 to 104, y 172 to 192 | 22 × 24 → 44 × 48 | Wrist extends 6 units up into the cuff | ±40° |
| `arm-r`, `fore-r`, `hand-r` | mirror of the left about x 128 | `[156, 126]`, `[162, 156]`, `[163, 178]` | mirrored | same sizes | same | mirrored ranges |
| `head` | torso | `[126, 112]` (neck) | x 74 to 165, y 34 to 118 | 96 × 94 → 192 × 188 | Neck extends 10 units below the chin under the hood; ears and beard painted on | ±12°, scale 0.9 to 1.1 |
| `hair` | head | `[122, 58]` | x 74 to 165, y 22 to 72 | 96 × 54 → 192 × 108 | Lower edge extends 12 units down over the forehead line as hair (it overlaps the head, it is not cut at the hairline) | ±6° (bounce), scale 0.94 to 1.06 |

That is 12 painted parts (hands counted once per variant set). Arms are two segments plus a hand so a wave, a brow-wipe and a hand on the hat all read. The arms are painted separately from the torso, hanging at the sides, so the torso image has no arms in it. Legs are one piece each, from the hem to the sneaker sole.

**Hand variants** (each side, same wrist pivot): `relaxed` (rest), `open` (palm out, waving), `grip` (fist with a gap a prop slots into, drawn as `grip-back` + `grip-front` around the prop), `thumb` (thumbs-up), `point-mouth` (fingertips up, for the giggle).

**Draw order** (back to front): `leg-l`, `leg-r`, `helmet-back`, `torso`, `head`, face layers, `hair`, `helmet-front`, `arm-l`, `fore-l`, prop (left), `hand-l`, `arm-r`, `fore-r`, prop (right), `hand-r`. Arms are in front of the torso at rest. A clip that moves a hand behind the head (stretch, inbox-zero hands behind head) sets `"drawOrder": {"arm-l": "back"}` to draw that whole arm chain before `torso`.

**Painted vs swapped.** Painted into `head`: skin, ears, the beard and moustache **with the mouth area left as beard with no mouth line**, nose, cheeks, and the eye sockets as plain skin. Swapped: eyes, brows, mouth. Hair is its own part so it can lag the head by a few degrees (follow-through) and so the helmet can sit over it.

### 2.4 Bones and roles

Clips address **roles**, not skin-specific parts, so one clip drives both skins:

| Role | Mona | Little Chris |
|---|---|---|
| `root` | root | root |
| `body` | body | torso |
| `head` | head | head |
| `hair` | (none, ignored) | hair |
| `arm-l`, `arm-r` | tentacle base | upper sleeve |
| `fore-l`, `fore-r` | tentacle tip | forearm |
| `hand-l`, `hand-r` | (tip variant, mapped to `fore-*` variant) | hand |
| `leg-l`, `leg-c`, `leg-r` | three front tentacles | two legs (`leg-c` ignored) |

A clip can carry per-skin overrides (`"skins": {"little-chris": {...}}`) for the few places a pose differs (the fidget: Mona curls a tip, Little Chris looks at a phone).

## 3. Face layers

A face is composited from small layers on the blank face plate painted into `head`. Layers are parented to `head`, so they rotate and squash with it. Whole-face swaps were considered and rejected: each whole face would be another generation of the head and would drift exactly as the frames did.

**Anchors.** Each skin has three face anchors measured on idle-00: `eye-l`, `eye-r` (pupil centres) and `mouth` (centre of the smile). Every eye or mouth image is authored centred on its anchor, so a swap never shifts the feature. A "look" moves both eye layers by up to ±4 units horizontally and ±3 vertically (the gaze offset); the plate itself does not move.

| Layer | Mona (≈ px at 2×) | Little Chris (≈ px at 2×) |
|---|---|---|
| Eye, per side | 48 × 52 | 52 × 52 |
| Brow, per side | none (no brows) | 52 × 24 |
| Mouth | 72 × 48 | 72 × 48 |
| Blush, per side (optional) | 40 × 24 | 40 × 24 |

**Eye set** (one image per side, so `wink` is just mixed sides):

| Key | Look | Used by |
|---|---|---|
| `open` | Rest eyes exactly as idle-00 | everything |
| `half` | Upper lid half down | blink in-between, sleepy, sheepish |
| `closed` | Gentle downward-curved line | blink, doze |
| `happy` | Upward arc, "^" | joy, giggle, inbox-zero, wink side |
| `wide` | Slightly larger, two highlights | notice, surprise, drag |
| `squeeze` | Tight ">" / "<" | flinch, pull-down of helmet, landing |
| `spiral` | Two bold turns, stroke ≥ 4 units | dizzy |

**Mouth set:** `smile` (rest), `grin` (open smile), `o` (small round), `wavy`, `yawn` (tall open oval), `flat` (determined, small straight), `giggle` (open smile with a tongue tip).

**Brows (Little Chris only):** `rest`, `up` (raised), `focus` (slightly lowered inner ends, determined, never angry), `worried` (inner ends raised, for dizzy and urgent).

**Expression presets** (named in clips; a clip key may also set layers directly):

| Preset | Eyes | Mouth | Brows |
|---|---|---|---|
| `neutral` | open | smile | rest |
| `notice` | wide | o | up |
| `joy` | happy | grin | up |
| `determined` | open | flat | focus |
| `flinch` | squeeze | grin | up |
| `giggle` | happy | giggle | up |
| `wink` | L open, R happy | grin | rest |
| `dizzy` | spiral | wavy | worried |
| `sleepy` | closed | smile | rest |
| `yawn` | closed | yawn | up |
| `sheepish` | half | smile | worried |

**Blink.** A blink is a face swap: `open → half → closed → half → open`. In the idle state it runs at today's idle cadence through the existing `IdleFrameSchedule`, so idle redraws only at those four instants (section 5.4). Inside a clip, the clip can schedule blinks as face keys.

## 4. Props as parts

All props are on the shared props sheet (section 6.3), painted for both skins' scale, and attach to a bone with an offset and a local rotation. A prop is either **held** (child of a hand or tentacle tip, drawn between `grip-back` and `grip-front`) or **worn** (child of the head).

| Prop | Parts | Size (≈ units → px) | Attach | Notes |
|---|---|---|---|---|
| Helmet, worn | `helmet-front` (dome, front brim, cream shield), `helmet-back` (the back brim that shows behind the head and at the sides) | Mona front 104 × 56, back 112 × 30; Little Chris front 96 × 54, back 104 × 28 (→ 2×) | `head`, at the head's `crown` point | Painted for the rig head's exact view: Mona straight front, Little Chris his exact slight turn in idle-00. Mona's ears tuck under the dome (the dome covers them). Little Chris's hair shows below the brim at the sides; the front dome covers the top of `hair`. Crown at y ≥ 20 after the 0.96 rest scale (validator). |
| Helmet, held | reuses `helmet-front` | same | `hand-*` / `fore-*` grip, rotated −25° (tilted brim toward the viewer) | `helmet-back` is hidden while held. One painting serves both, so the helmet is identical in the hand and on the head. |
| Extinguisher | `extinguisher` (cylinder, handle and lever), `nozzle` (short hose ending in a steel cone) | 34 × 52 and 30 × 22 | body to `hand-l` grip, nozzle to `hand-r` (Mona: the other tentacle tip) | `nozzle` has a `spray` point at the cone tip, which drives the mist FX instead of `framePoints.nozzle`. |
| Envelope | `envelope` | 48 × 34 | `hand-l` grip | Cream, closed flap, pale blue seal, no writing. |
| Phone (Little Chris) | `phone` | 20 × 32 | `hand-r` grip | Dark rounded rectangle, soft blue screen glow, no UI. |

The firefighter hat accessory in v1/v2 terms becomes "helmet worn": the engine shows `helmet-front` + `helmet-back` on the rig whenever `IncidentMarker.current` is non-nil, on every pose, exactly by the v1 rules (section 3.1 of animation-v1). `incident-start` and `incident-end` animate the helmet themselves (`"accessories": "hide"` as today) and end in the worn or unworn attachment, so the hand-off is seamless by construction.

## 5. Motion language

### 5.1 Easing library (pure functions of normalized time `u` in 0…1)

| Name | Curve | Use |
|---|---|---|
| `linear` | `u` | rarely; procedural phase only |
| `hold` | 0 until 1 | face and variant swaps, draw order |
| `inOut` | cubic-bezier(0.45, 0, 0.55, 1) | default for poses that start and end at rest |
| `out` | cubic-bezier(0.22, 1, 0.36, 1) (fast start, soft land) | reactions, moving into a pose |
| `in` | cubic-bezier(0.55, 0, 1, 0.45) | falling, wind-up before a release |
| `back` | ease-out-back, overshoot `s = 1.4` (≈ 8% past) | arriving poses with snap: arm raise, envelope pop |
| `spring` | `1 − e^(−u·d)·cos(u·f·2π)` with `d = 5`, `f = 1.5` (two visible wobbles) | settles: landing, a prop popping in, head nods |

All curves are closed-form, so every value is a pure function of `(clip start, now)`, matching the single-clock rule. There is no per-frame physics state.

### 5.2 Principles and the default numbers

- **Anticipation.** Any move bigger than 15° or 6 units starts with a small opposite move: 80 to 160 ms, 15 to 25% of the main move's size. A raise dips first; a hop crouches first.
- **Squash and stretch on the ground anchor.** Only `root` squashes, about `[128, 232]`, so the feet never leave the ground line unless the clip translates `root.y`. Area is roughly preserved: `sx = 1 / sqrt(sy)`. Limits: `sy` 0.88 to 1.08. The head counter-squashes a little (`head.sy` moves 30% of the opposite way) so the face stays round and readable.
- **Overlap and follow-through (the `follow` track).** A child can follow a parent's rotation with a delay and gain: `θchild(t) = θrest + gain · (θparent(t − delay) − θparent(t))`. Defaults: head follows body (delay 40 ms, gain 0.6); hair follows head (60 ms, 0.8); tentacle tips follow their bases (70 ms, 1.3); Little Chris forearms follow upper arms (50 ms, 0.7); held props follow their hand (40 ms, 0.4). Delayed samples are just the same curve evaluated earlier, so this stays pure.
- **Secondary motion (the `sway` track).** Mona's legs and resting tips sway as damped sines while a clip plays: `θ = A · sin(2π (t − φ) / T) · env(t)` with `A` 3 to 6°, `T` 900 to 1300 ms, a phase `φ` that grows 120 ms per leg from left to right (so a wave travels across), and `env` fading in over 200 ms and out over the clip's last 300 ms to exactly 0, so the clip ends on the rest pose. Little Chris's hair gets a 2° sway on hops and landings only.
- **Arcs.** Hands and tips move on arcs because they are rotations of segments; translation of `root` is the only straight-line motion and is always paired with rotation of something.
- **Holds are moving holds.** A "held" beat keeps a 1 to 2% drift (a slow `inOut` over the beat) so the character never freezes mid-clip.
- **Clip edges.** Every clip starts from the current pose and ends on the pose it hands back to (idle rest, or the mood's attention or urgent pose). The engine blends transforms over the first 120 ms from whatever was showing (an idle frame, a preempted clip at the preemption instant) and over the last 150 ms into the hand-back pose. Faces and variants snap (swaps are instant, which reads as a blink-speed change). This replaces v1's "new clip starts at frame 0 with no blend": priorities and preemption are unchanged, only the visual joint is smoothed.
- **Lean.** The #29 lean (±5° about the anchor) becomes `root.rot`. The drag lean uses the same smoothed velocity and spring-back as today.

### 5.3 States as poses

| State | Pose (offsets from rest) | Face |
|---|---|---|
| `idle` | rest | `neutral`, blink loop at today's cadence: `open` 3800 · `half` 125 · `closed` 125 · `half` 125 ms (4175 ms loop) |
| `attention` | `root.sy` 1.02, `head.rot` −3, `arm-r` −35 (raised a little, waving height), `fore-r` −20 | `notice` with `mouth: smile` |
| `urgent` | `root.sy` 0.98, `head.rot` 0, both arms in toward the chest (`arm-l` +15, `arm-r` −15), `fore-*` +40 | Mona `open` + `flat`; Little Chris adds `worried` brows. Calm concern, never fear. |
| `drag` (held) | `root.sy` 1.05, legs and tips dangle (procedural sway 8°, T 800 ms), arms out 20° | `notice` → `joy` after 400 ms |
| `doze` (held) | `root.sy` breathes 0.97 ↔ 0.99 (`inOut`, 2400 ms loop), `head.y` +6, `head.rot` +4 | `sleepy` |
| Static fallback (Reduce Motion) | the same poses with no motion | first face of the state |

### 5.4 Clip keyframes

Notation: `t ms: value ease` (the ease is the curve used to arrive at that key). Unlisted bones stay at rest. `root.sy` implies `root.sx` by the squash rule. Arms: negative `arm-l` rotation raises the left arm outward and up; positive `arm-r` rotation raises the right arm (mirrored). Lengths match v1, within v1's per-clip caps.

**`new-item`, 1900 ms (perk up with an envelope).**

| Track | Keys |
|---|---|
| `root.sy` | 0: 1 · 120: 1.05 `out` · 300: 0.90 `inOut` (anticipation crouch) · 460: 1.07 `out` (spring up) · 620: 0.95 `in` (land) · 900: 1 `spring` · 1900: 1 |
| `root.y` | 0: 0 · 300: 0 · 460: −7 `out` · 620: 0 `in` |
| `head.rot` | 0: 0 · 120: −4 `out` · 460: 3 `inOut` · 900: 0 `spring` · 1000 to 1500: ±3 opposite phase to the waggle · 1900: 0 |
| `arm-l` | 0: 0 · 300: 10 `inOut` (dip) · 560: −118 `back` (envelope up beside the head, viewer's left) · 1300: −118 · 1600: −45 `inOut` (down to the chest) |
| `fore-l` | follow arm-l (70 ms, 1.3) · 560 to 1300: waggle ±18° about −25°, period 260 ms, `inOut` (two and a half cycles) · 1600: 50 `inOut` |
| `arm-r` | follow body sway; 1450: 0 · 1650: 40 `inOut` (comes in to hold the envelope with both) |
| `envelope` | attached to `hand-l` from 240 ms: scale 0 → 1 `back` over 180 ms (pops in from behind), follow hand (40 ms, 0.4) |
| face | 0: `notice` · 460: `joy` · 1300: `neutral` with `mouth: grin` · 1700: blink (half 60, closed 80, half 60) |
| sway | Mona legs, A 5°, T 1000 ms |
| End | hands back to the `attention` pose (blend 150 ms; the envelope scales to 0 over the blend) |

**`item-cleared`, 1200 ms (thumbs-up).** `root.sy` 0: 1 · 140: 0.96 `inOut` · 360: 1.03 `out` · 700: 1 `spring`. `head.rot` 0: 0 · 200: 5 `out` (glance down-left, eyes offset (−3, +2)) · 500: −2 `inOut` · 1100: 0. `arm-r` 120: 10 `in` (dip) · 380: 105 `back` (shoulder height) · 1000: 105 · 1200: 0 `inOut`. `hand-r` / tip variant `thumb` / `curl` from 300 ms. Face: 0 `neutral` · 200 `joy` · 520 `wink` · 1000 `neutral`. Sparkle FX at the hand's world position at 380 ms (v1 timing and y ≥ 76 clamp).

**`inbox-zero`, 2000 ms (happy dance).** Two steps then a "yay". `root.rot` 0: 0 · 250: −5 `inOut` · 550: 5 `inOut` · 850: −5 `inOut` · 1150: 0 `out`. `root.sy` bounces 0.94 at each step centre (250, 550, 850) and 1.06 between, `inOut`. `arm-l` / `arm-r` alternate up-and-out: the arm on the side the body leans away from rises to 100° `back`, the other drops to 20°. 1150: both to 125° `back` ("yay" V, outward diagonals, kept below the y 20 line) · 1600: both to the relaxed pose (Mona: −20 / 20 with tips `curl`; Little Chris: hands behind the head, `drawOrder` back, `fore-*` 130) `inOut`. Face: 0 `notice` · 250 `joy` · 1600 `neutral` with `eyes: happy`. Legs sway A 6°, T 600 ms (dance tempo). Three sparkles at 1150 ms (v1 positions).

**`incident-start`, 1900 ms (helmet on).** 0 to 250: notice: `head.rot` −5 `out`, eyes offset (−4, +3) toward the siren, face `notice`. 250 to 550: `arm-l` −60 `back` brings the held helmet to chest height (helmet attached to `hand-l` from 200 ms, scale-in 0 → 1 `back` 150 ms). 550 to 850: both arms raise (`arm-l` −140, `arm-r` 140, `inOut`), helmet travels up in front of the face on an arc; `root.sy` 1.04. At 850 the helmet re-parents from the hand to the head's `crown` (worn), arriving tilted 12° and 6 units high. 850 to 1150: pull-down: helmet offset to 0 and tilt to 3° `spring`; `root.sy` 0.93 `in` then 1 `spring`; face `squeeze` + grin. 1150 to 1500: a determined nod: `head.rot` 0 and `head.y` +4 `inOut` then back; arms to hips (`arm-l` 25, `fore-l` 110, mirrored) `back`; face `determined`. 1500 to 1900: settle; helmet tilt 3 → 0 `spring`; arms back to rest. Ends on the idle pose with the helmet worn, identical to the held accessory.

**`incident-end`, 2700 ms (extinguish and phew).** Helmet worn throughout until 2000. 0 to 300: extinguisher pops in at `hand-l` (scale `back`), nozzle at `hand-r`; face `joy`. 300 to 550: brace: `root.sy` 0.95, `root.rot` −3, `arm-l` 20, `arm-r` −50 aiming the nozzle down-left `inOut`. 550 to 1450: spray: `root.rot` −3 → +2 `inOut` (recoil), a 40 ms `spring` jitter of 1° on `body` at 550; the nozzle sweeps from aim −20° to −40° (lower) `inOut`. Mist FX every 60 ms from the nozzle's `spray` point (v1 timing, now attached to the moving nozzle). 1450 to 1750: lower the extinguisher (scale 1 → 0 over 200 ms at the end), look down-left, face `neutral` with `eyes: happy`. 1750 to 2000: `arm-r` lifts to the helmet (`arm-r` 150, `fore-r` 60), the helmet re-parents to `hand-r` at 2000 (held variant). 2000 to 2500: phew: helmet lowered to chest height, `arm-l` −150 with `fore-l` 120 wiping the brow (a ±10° `fore-l` swipe, 2 passes), `root.sy` 1.03 → 0.97 (exhale), face `joy` with `mouth: grin`. 2500 to 2700: helmet scales out in the hand, arms to rest, idle face. Siren and flame extinguish FX as v1.

**`drop`, 450 ms.** `root.sy` 0: 1.05 (the drag pose) · 90: 0.88 `in` (landing squash) · 220: 1.05 `out` (rebound) · 450: 1 `spring`. `head.sy` counter. Legs/arms splay 15° out at 90 then `spring` in. Face `squeeze` at 0, `joy` at 220. The drag lean springs to 0 over 200 ms as today.

**`poke`, 750 ms.** `root.rot` 0: 0 · 90: +5 `out` (away from the click side; mirrored if the click was right of centre) · 450: 0 `spring`. `root.sy` 90: 0.93 · 300: 1.02 · 750: 1 `spring`. Shoulders up: `arm-l` 15, `arm-r` −15 at 90 `out`. 250 to 650: `arm-l` −70 with `fore-l` 110 (hand or tip to the mouth, Little Chris `hand-l: point-mouth`). Face 0 `flinch` · 250 `giggle` · 650 `neutral`.

**`dizzy`, 1600 ms.** `root.rot` 0, −6, +6, −6, 0 at 0, 300, 600, 900, 1250, `inOut` (v1 wobble, now continuous). `head.rot` follows root (60 ms, 1.4) so the head lolls. Arms loose: sway A 12°, T 600 ms. Face 0 `dizzy` · 1250 `sheepish`. 1250 to 1500: shake it off: `head.rot` ±6° two quick cycles, 120 ms each, `inOut`. Eye spirals rotate 0 → 360° over 1200 ms (a layer rotation about the eye anchor).

**`idle-look`, 2000 ms.** Eyes only plus a small head tilt. Gaze offset 0: (0, 0) · 300: (−4, 0) `out` · 900: (−4, 0) · 1100: (4, 0) `out` · 1400: (3, −3) `inOut` with `head.rot` −4 and `head.y` −2 (looking up toward the menu bar) · 1800: (0, 0) `inOut`. Blink at 1000 (the change of direction).

**`idle-stretch`, 2400 ms.** 0 to 400: `root.sy` 0.96 `inOut`, face `yawn` (eyes closed, small open mouth). 400 to 1000: big stretch: `root.sy` 1.07 `out`, `body.rot` 0 with `head.rot` −6 (arching back), arms out and slightly up (`arm-l` −105, `arm-r` 105, `fore-*` −20) `inOut`; Mona tips `straight`, quivering ±4° at 80 ms period. 1000 to 1500: hold (moving hold), mouth `yawn`. 1500 to 1900: relax: `root.sy` 0.97 `in`, arms drop past rest by 8° then `spring`. 1900 to 2400: settle, face `neutral` with `eyes: happy`, then blink.

**`idle-fidget`, 1800 ms.** Mona: `arm-r-tip` switches to `curl` at 300 ms and the whole `arm-r` waves ±14° (two cycles of 350 ms, `inOut`), then 1100 ms the left tip curls once (`arm-l-tip` `curl` 1100 to 1500) and both return. Face `neutral` → `happy` eyes at 500. Little Chris: 0 to 400: `arm-r` −10 and `fore-r` 70 bring `hand-r` (variant `grip`) to the front pocket, phone scales in at 350 ms; 400 to 1100: phone held at chest, `head.rot` 6 and `head.y` 3 (looking down), eyes offset (0, +3); 1100 to 1500: small smile, phone back down, scales out at 1450; 1500 to 1800: rest.

**`doze` (held state).** See section 5.3. Z FX unchanged (v1 timing). Runs at 8 fps like today; the breathing is slow enough that 8 fps reads smooth.

### 5.5 Timings and frame rate

- 60 fps target while a clip, drag or spring runs (2 s bursts), falling back to 30 fps if D2 measurements show a frame costs more than 1.5 ms on the main thread at 128 pt. Doze and the placeholder breathing stay at 8 fps.
- Idle never runs a continuous timeline (section 7.4).

## 6. Codex art brief

### 6.0 How the parts stay on-model and separable

1. **Every sheet is an "exploded view" of the existing idle-00.** Pass the skin's `frames/idle-00.png` (Mona also `sources/probe.png`; Little Chris `source/little-chris-poses.png`) as identity references. The prompt asks for the same character, same scale as idle-00, taken apart. Codex paints the hidden parts of each piece (the tentacle root under the head, the neck, the arm under the sleeve) which idle-00 cannot give us.
2. **Islands, not grid cells.** Each part is one isolated island separated from every other island by at least 40 px of fully transparent background. The cutter splits sheets by connected components (alpha > 8), so cell boundaries do not matter and partial sheets still cut.
3. **A scale reference on every sheet.** Each parts sheet includes the fully assembled character (rest pose) in the top-left corner, at the same scale as the parts. The builder uses it to normalize the sheet's scale to idle-00 and to register each part (template match against the assembled reference, translation plus ±10% scale).
4. **Plain, unlit-by-environment parts.** No cast shadows, no ground, no background, no glow, no motion lines, no text. Light from the upper left, the same soft painted tone and dark contour as idle-00.
5. **One generation per sheet, then edits.** If a sheet is close, edit it with a preserve list (the image-generation skill's pattern) rather than regenerating, so the parts that are right stay right.
6. **Faces are drawn on the blank head.** The face sheet first shows the blank head (from the parts sheet) as the reference, then the features alone at the same scale. That keeps eye size and spacing on-model.

Sizes: request 1254 × 1254 (the integration's sheet size) with transparent background. At that size the parts sheets render about 2.2 to 2.6 px per canvas unit, enough for 2× parts after the normalizing resample.

### 6.1 Priority order (a partial run still yields a working rig)

| # | Sheet | File | Unlocks |
|---|---|---|---|
| 1 | Mona parts | `assets/mascots/mona-pet-v1/rig/sources/parts-sheet.png` | Mona rig moves (idle, drop, poke, dizzy, look, stretch, fidget, doze) with idle-00's face cut as a fallback face |
| 2 | Mona face layers | `.../mona-pet-v1/rig/sources/face-sheet.png` | Mona expressions and blink |
| 3 | Props as parts | `assets/mascots/shared-fx-v1/sources/props-parts-sheet.png` | new-item, incident-start, incident-end on Mona |
| 4 | Mona tip variants (if sheet 1 did not include them cleanly) | `.../mona-pet-v1/rig/sources/tips-sheet.png` | thumbs-up loop, holding props |
| 5 | Little Chris parts | `assets/mascots/little-chris-v1/rig/sources/parts-sheet.png` | Little Chris rig |
| 6 | Little Chris face layers | `.../little-chris-v1/rig/sources/face-sheet.png` | his expressions |
| 7 | Little Chris hands | `.../little-chris-v1/rig/sources/hands-sheet.png` | thumbs-up, wave, grip, giggle |
| 8 | Helmet fit check (both skins, one sheet) | `assets/mascots/shared-fx-v1/sources/helmet-fit-sheet.png` | Not bundled. Reference for placing the worn helmet. |

Record each generation in `docs/design/provenance.md` (artifact ID, prompt intent, reference hashes), as for v1 and v2.

### 6.2 Prompts

The text below is the exact prompt. Attach the listed references in this order.

**Sheet 1: Mona parts.** References: (1) `mona-pet-v1/frames/idle-00.png`, the character and the exact scale; (2) `mona-pet-v1/sources/probe.png`, identity.

> A clean character "exploded view" sprite sheet for 2D cutout animation, on a fully transparent background, 1254 × 1254. The character is the friendly black cat-octopus in reference image 1: near-black body with soft gray highlights, a cream face mask, small cat ears, whiskers and soft dark contour, painted in the same soft continuous tone, lit from the upper left. Keep the exact proportions, colours, outline weight and head scale of reference image 1.
>
> Top-left corner: the whole character assembled in its standing rest pose, exactly like reference image 1, at the same size as reference image 1 appears at 300 pixels tall. Every other piece on the sheet is drawn at that same scale.
>
> Then lay out the character's separate body parts, each as its own isolated piece with at least 40 pixels of empty transparent space around it, none touching:
> 1. The head with the hood and both cat ears, front view, with the cream face mask painted completely blank: whiskers and the soft cheek shading only, no eyes, no mouth, no nose. The neck continues about a fifth of the head's height below the chin as plain black, ending in a rounded edge.
> 2. The body: the black rounded mantle under the head, with two short stubby tentacles behind painted in. Its top continues upward as plain black, rounded, where the head will cover it.
> 3. Three front tentacles, each drawn separately and hanging straight down with a gentle curl at the tip, each with a rounded top end where it joins the body.
> 4. The left arm tentacle in two pieces: an upper section with a rounded top, and a separate tip section with a rounded end where it joins, drawn hanging down.
> 5. The right arm tentacle in the same two pieces, drawn hanging down, mirrored.
> 6. Below those, extra versions of a tentacle tip, for both left and right: one curled into a neat round loop, and one wrapped in a C shape as if gripping a small object, drawn as two pieces (the part behind the object and the part in front of it).
>
> Every piece is complete on its own, including the areas normally hidden where it overlaps another piece. Soft painted style, clean dark contour, no cast shadows, no ground, no background, no glow, no motion lines. No text, no labels, no numbers, no logos, no watermark.

**Sheet 2: Mona face layers.** References: (1) sheet 1, the blank head; (2) `mona-pet-v1/frames/idle-00.png`, the rest eyes and smile.

> A transparent sprite sheet of facial features for the blank-faced cat-octopus head in reference image 1, 1254 × 1254, painted to match the eyes and mouth in reference image 2 exactly in size, colour, highlight and line weight.
>
> Top-left: the blank head from reference image 1, unchanged, as a size reference. Every feature is drawn at the scale it would have on that head.
>
> Then draw each feature as its own isolated piece with at least 40 pixels of transparent space around it. Arrange them in rows. Each eye row shows the viewer's left eye, then the viewer's right eye:
> - Row 1 eyes: open (exactly as in reference image 2); half-closed (upper lid half down); closed (a gentle downward-curving line).
> - Row 2 eyes: happy closed (an upward arc); wide open and slightly larger with two highlights; squeezed shut (tight angle shapes).
> - Row 3 eyes: dizzy spirals with two bold turns and a thick line.
> - Row 4 mouths, each alone: the small smile from reference image 2; an open grin; a small round "o"; a wavy line; a tall open yawn; a short straight determined line; an open giggle with a small tongue tip.
> - Row 5: two soft pink blush ovals.
>
> Features only, no face plate behind them except where the feature itself is filled. Same soft painted style and dark contour. No shadows, no background, no text, no labels, no numbers, no watermark.

**Sheet 3: Props as parts.** References: (1) sheet 1, Mona's blank head; (2) sheet 5 head if it already exists, otherwise `little-chris-v1/frames/idle-00.png`; (3) `shared-fx-v1/sources/props-reference.png`, the props' design.

> A transparent sprite sheet of small props for 2D cutout animation, 1254 × 1254, in the same soft painted style with a clean dark contour as reference image 1, lit from the upper left. Each prop is its own isolated piece with at least 40 pixels of transparent space around it. Use the prop designs from reference image 3.
>
> 1. A firefighter helmet sized to fit the head in reference image 1, drawn in exactly that head's straight-on front view, in two separate pieces: (a) the front piece: the glossy red dome, the front brim and a plain cream shield badge with no text or emblem; its lower edge is shaped to sit snugly on the top of that head and cover both cat ears; (b) the back piece: only the part of the back brim that would show behind and beside that head.
> 2. The same helmet sized and angled for the head in reference image 2, keeping exactly that head's slight turn: the same two pieces, front and back, matched to that head's turn.
> 3. A small stubby red fire extinguisher with a steel handle and lever, upright, no label, without its hose.
> 4. A short black hose ending in a steel nozzle cone, as a separate piece.
> 5. A cream envelope with the flap closed and a small pale blue round seal.
> 6. A small dark rounded phone with a soft blue glowing screen and nothing on the screen.
>
> Each prop is the size it would be when held by the character in reference image 1 (the envelope about a third of the head's width). No hands or tentacles, no shadows, no background, no spray, no text, no numbers, no logos, no watermark.

**Sheet 4: Mona tip variants** (only if sheet 1's row 6 is missing or messy). References: sheet 1.

> Using the tentacle tip pieces from reference image 1, draw extra left and right tentacle tips at exactly the same scale and style: one curled into a neat round loop, one wrapped in a C shape gripping a small object, the grip shown as two separate pieces (behind the object and in front of it). Each piece isolated with at least 40 pixels of transparent space, rounded ends where they join. No shadows, background, text or watermark.

**Sheet 5: Little Chris parts.** References: (1) `little-chris-v1/frames/idle-00.png`, character and exact scale; (2) `little-chris-v1/source/little-chris-poses.png`, identity.

> A clean character "exploded view" sprite sheet for 2D cutout animation, on a fully transparent background, 1254 × 1254. The character is the chibi man in reference image 1: big head, warm brown curly hair, a full brown beard and moustache, navy hoodie with white drawstrings and a front pocket, tan trousers, dark navy and white sneakers. Keep the exact proportions, colours, outline weight and head scale of reference image 1, and keep his head at exactly the slight turn it has in reference image 1. Soft painted continuous tone, lit from the upper left, keeping the light rim on the hoodie.
>
> Top-left corner: the whole character assembled in his standing rest pose, exactly like reference image 1, about 400 pixels tall. Every other piece is drawn at that same scale.
>
> Then lay out his separate body parts, each isolated with at least 40 pixels of empty transparent space around it, none touching:
> 1. The head without hair, ears included, with the beard and moustache, nose and cheeks, but the eyes, eyebrows and mouth left out: plain skin where the eyes and brows go, and beard where the mouth goes. The neck continues below the beard as plain skin, ending in a rounded edge.
> 2. The hair alone, as a separate cap of curly brown hair, its lower edge extending a little below the hairline so it overlaps the forehead.
> 3. The torso: the hoodie body with the hood around the neck, drawstrings and pocket, with no arms. The shoulder openings are rounded and filled with the hoodie colour.
> 4. Each arm in two pieces, left and right: the upper sleeve with a rounded shoulder end and a rounded elbow end, and the lower sleeve with its cuff, rounded at the elbow end. Drawn hanging straight down.
> 5. Each leg as one piece, left and right: tan trouser leg with a rounded top end, and the sneaker.
>
> Every piece is complete on its own, including the areas normally hidden where it overlaps another piece. No hands on this sheet. No cast shadows, no ground, no background, no glow, no motion lines. No text, no labels, no numbers, no logos, no watermark.

**Sheet 6: Little Chris face layers.** References: (1) sheet 5, the blank head; (2) `little-chris-v1/frames/idle-00.png`.

> A transparent sprite sheet of facial features for the blank-faced head in reference image 1, 1254 × 1254, painted to match the eyes, eyebrows and mouth in reference image 2 exactly in size, colour, iris colour, highlight and line weight, for that head at its exact slight turn.
>
> Top-left: the blank head from reference image 1, unchanged, as a size reference. Every feature is drawn at the scale it would have on that head.
>
> Then each feature as its own isolated piece with at least 40 pixels of transparent space around it, in rows. Each eye and eyebrow row shows the viewer's left one, then the viewer's right one:
> - Row 1 eyes: open (exactly as in reference image 2, brown iris, white highlight); half-closed; closed (a gentle downward-curving line with lashes).
> - Row 2 eyes: happy closed (an upward arc); wide open with two highlights; squeezed shut.
> - Row 3 eyes: dizzy spirals with two bold turns and a thick line.
> - Row 4 eyebrows: resting (as in reference image 2); raised; focused (inner ends slightly lowered, calm, not angry); worried (inner ends raised).
> - Row 5 mouths, each alone, drawn to sit inside the beard: the open smile from reference image 2; a big open grin; a small round "o"; a wavy line; a tall open yawn; a short straight determined line; an open giggle with a small tongue tip.
> - Row 6: two soft blush ovals.
>
> Features only. Same soft painted style and dark contour. No shadows, background, text, labels, numbers or watermark.

**Sheet 7: Little Chris hands.** References: (1) sheet 5; (2) `little-chris-v1/frames/idle-00.png`.

> A transparent sprite sheet of simple cartoon hands for the character in reference image 2, at exactly the scale of the arms in reference image 1, same skin tone, soft painted style and dark contour, lit from the upper left. Each hand ends at the wrist with a short rounded wrist stub that will slide inside the sleeve cuff. Each hand is its own isolated piece with at least 40 pixels of transparent space around it. Draw a left and a right version of each: relaxed hanging hand; open hand with the palm toward the viewer, waving; a fist with a gap for holding a small object, drawn as two pieces (the back of the hand, and the curled fingers in front of the object); a thumbs-up; fingertips raised to the mouth, giggling. Simple four-finger-and-thumb shapes. No shadows, background, text or watermark.

**Sheet 8: Helmet fit check** (not bundled). References: sheet 1 head, sheet 5 head and hair, sheet 3 helmets.

> Two images side by side on a transparent background: the head from reference image 1 wearing the matching helmet from reference image 3, and the head with hair from reference image 2 wearing its matching helmet from reference image 3. The helmet sits low and snug on the head, as if really worn: the brim rests just above the eyes' position, the cat ears are hidden under the dome, the curly hair shows below the brim at the sides. Same scale, same style, no shadows, no background, no text.

### 6.3 Validation checklist (PM, when a sheet lands)

Apply in order; a "no" on 1 to 4 means regenerate, on 5 to 8 means an edit pass.

1. **Transparent.** The corners and the gaps between parts are alpha 0. No background colour, ground, shadow or glow.
2. **Separable.** Every part is its own island with a clear gap (no touching, no thin bridges). `python3 -B docs/design/rig_cut.py --check <sheet>` (D3 tool) lists the islands and their sizes; the count matches the prompt.
3. **On-model.** Next to idle-00 at the same scale (the assembled reference in the corner): same head width (Mona ≈ 150 units, Little Chris ≈ 92 units after normalizing), same ear shape, hair shape, outline weight and colours. Mona reads as the same character, not a different cat.
4. **Clean content.** No text, letters, numbers, logos, watermarks, motion lines or sparkles. The helmet shield is blank.
5. **Blank faces.** The head parts have no eyes, mouth or brows (Mona's whiskers and cheek shading stay; Little Chris's beard stays, with no mouth line).
6. **Joint ends.** Every limb piece has rounded, filled ends where it joins; no straight cut edges, no outline across the joint end.
7. **Complete hidden areas.** The body continues under the head, the neck under the hood, the tentacle roots under the body. Nothing is cut off where a neighbour would cover it.
8. **Consistent view and light.** Parts face the same way as idle-00 (Mona front-on, Little Chris at his idle-00 turn), light from the upper left on every part. Faces: features match the rest eyes' size and spacing on the blank head. Helmets: the front piece's lower edge follows the head's curve, not a straight line.

After the PM's check the designer cuts and assembles (section 6.4) and judges the assembled rest pose against idle-00 by eye on a contact sheet.

### 6.4 Assembly (designer, D3)

1. `rig_cut.py` splits each sheet into islands (alpha > 8, 8-connected), crops each with a 4 px margin and names them by layout order, which the designer confirms on a contact sheet.
2. It normalizes the sheet's scale so the assembled reference matches idle-00 (head width), then resamples the parts to 2 px per unit.
3. It proposes each part's rest offset by matching it against the assembled reference (and idle-00), then the designer adjusts pivots and offsets in `rig.json` and re-renders the rest pose next to idle-00 until they agree.
4. Face anchors are measured on idle-00's eyes and mouth.

## 7. Engine plan

### 7.1 Pack format: schema v3

v1 and v2 manifests keep loading unchanged (frame packs, the current path). A v3 manifest adds a `rig` section and uses rig poses for its states and clips. A v3 pack has no frames.

```json
{
  "schemaVersion": 3,
  "id": "mona-pet-v1",
  "name": "Mona-inspired Pet",
  "canvas": { "width": 256, "height": 256 },
  "anchor": [128, 232],
  "rig": {
    "unitScale": 2,
    "restScale": 0.96,
    "parts": {
      "body":     { "image": "rig/body.png", "bone": "body", "origin": [72, 118] },
      "head":     { "image": "rig/head.png", "bone": "head", "origin": [40, 14] },
      "arm-l-tip":{ "image": "rig/arm-l-tip.png", "bone": "fore-l", "origin": [50, 186], "variant": "straight",
                    "variants": { "curl": "rig/arm-l-tip-curl.png", "grip": "rig/arm-l-tip-grip-back.png" } }
    },
    "bones": {
      "root":   { "pivot": [128, 232] },
      "body":   { "parent": "root", "pivot": [128, 196], "rot": [-6, 6] },
      "head":   { "parent": "body", "pivot": [128, 136], "rot": [-12, 12], "points": { "crown": [128, 26] } },
      "fore-l": { "parent": "arm-l", "pivot": [64, 196], "rot": [-70, 70] }
    },
    "drawOrder": ["leg-l", "leg-r", "leg-c", "body", "arm-l", "arm-l-tip", "arm-r", "arm-r-tip",
                  "helmet-back", "head", "@face", "helmet-front"],
    "face": {
      "anchors": { "eye-l": [102, 96], "eye-r": [154, 96], "mouth": [128, 118] },
      "eyes":   { "open": ["rig/face/eye-l-open.png", "rig/face/eye-r-open.png"], "closed": ["...", "..."] },
      "mouths": { "smile": "rig/face/mouth-smile.png" },
      "presets": { "neutral": { "eyes": "open", "mouth": "smile" } }
    },
    "props": {
      "helmet": { "front": "props/helmet-mona-front.png", "back": "props/helmet-mona-back.png",
                  "worn": { "bone": "head", "point": "crown", "offset": [0, 0] } },
      "envelope": { "image": "props/envelope.png", "grip": [24, 17] }
    }
  },
  "states": {
    "idle":      { "pose": {}, "faces": ["neutral", {"eyes": "half"}, {"eyes": "closed"}, {"eyes": "half"}],
                   "durationMs": [3800, 125, 125, 125], "loop": true },
    "attention": { "pose": { "root": { "sy": 1.02 }, "head": { "rot": -3 }, "arm-r": { "rot": -35 } }, "face": "notice" },
    "urgent":    { "pose": { "...": "..." }, "face": "neutral" },
    "drag":      { "pose": { "...": "..." }, "face": "notice", "procedural": [{ "sway": ["leg-l", "leg-c", "leg-r"], "amp": 8, "periodMs": 800 }] },
    "doze":      { "...": "..." }
  },
  "clips": {
    "new-item": {
      "durationMs": 1900,
      "tracks": {
        "root.sy": [[0, 1], [120, 1.05, "out"], [300, 0.9, "inOut"], [460, 1.07, "out"], [620, 0.95, "in"], [900, 1, "spring"]],
        "root.y":  [[0, 0], [300, 0], [460, -7, "out"], [620, 0, "in"]],
        "arm-l.rot": [[0, 0], [300, 10, "inOut"], [560, -118, "back"], [1300, -118], [1600, -45, "inOut"]]
      },
      "follow": [{ "bone": "fore-l", "of": "arm-l", "delayMs": 70, "gain": 1.3 }],
      "sway": [{ "bones": ["leg-l", "leg-c", "leg-r"], "amp": 5, "periodMs": 1000, "phaseStepMs": 120 }],
      "faces": [[0, "notice"], [460, "joy"], [1300, { "preset": "neutral", "mouth": "grin" }]],
      "props": [[240, { "envelope": { "attach": "hand-l", "in": "back", "inMs": 180 } }]],
      "endsOn": "attention",
      "accessories": "keep"
    }
  },
  "fileSha256": { "...": "every referenced PNG" }
}
```

**Semantics.**

- Bones form a tree rooted at `root`, depth ≤ 6, ≤ 24 bones. Unknown parents, cycles, or a missing `root` are errors.
- `origin` is where the part image's top-left sits in the rest pose, in canvas units (before `restScale`). A part's pixel size divided by `unitScale` is its size in units.
- A pose is a map of bone → `{x, y, rot, sx, sy}` offsets from rest. A track key is `[ms, value, ease?]`; the first key has no ease. Values are clamped to the bone's declared ranges at load (out-of-range is an error in bundled packs, a clamp in custom packs).
- Allowed eases: `linear`, `hold`, `inOut`, `out`, `in`, `back`, `spring`. Allowed procedural kinds: `follow`, `sway`. Nothing else is executable: a pack is data.
- Clip keys must come from the v1 known set. Clip `durationMs` respects v1's per-clip caps. `endsOn` is `idle` (default) or the mood pose.
- Budgets: ≤ 64 part, variant, face and prop images; each image ≤ 1024 × 1024 px and ≤ 4 MiB; pack ≤ 16 MiB (bundled: ≤ 48 images, ≤ 160 KiB each, ≤ 3 MiB). ≤ 40 tracks per clip, ≤ 48 keys per track.
- `validate_pack.py` checks v3 too: the tree, ranges, image budgets, checksums, and the bounds rule by sampling every clip and state (section 7.5).

### 7.2 Core (GitHubPetCore, pure and tested)

- `Rig` (decoded, validated `rig` section) and `RigClip`.
- `RigEvaluator.pose(rig:, state:, clip:, elapsed:, blendFrom:) -> RigPose`: evaluates tracks, `follow` and `sway`, composes world transforms down the tree, applies the edge blends, and returns per-part `(image key, CGAffineTransform, opacity)` in draw order plus face selection and prop attachments. A pure function of its inputs, so tests pin it at any millisecond.
- `Easing` with the curves of section 5.1.
- `RigContour`: each part keeps a precomputed outline (its alpha > 8 boundary, simplified to ≤ 48 points). The top contour of a pose is the transformed outlines' upper envelope over 256 columns: microseconds, no rasterizing. The count's near-touch tracking uses it per drawn frame, exactly like today's per-frame contours.
- `MascotAnimator.pose` keeps choosing *what* plays (priorities, gating, drag, doze). For a rig pack, `ClipFrame` carries `elapsed` and the renderer evaluates the rig instead of looking up a frame image. `ClipLibrary` reads durations from rig clips, so `EventClipQueue` and `ClipScheduler` are unchanged.

### 7.3 Renderer (app target)

- `RigFigure` draws a `RigPose` in a SwiftUI `Canvas` (one `GraphicsContext`, resolved images cached per part, `concatenate` transform, `draw`). It sits where `PackFigure` sits now, inside the same `TimelineView`, so render-check and `ImageRenderer` snapshots work unchanged.
- If D2 measurements show the Canvas path above the budget, the live window switches to a `CALayer` per part (GPU-composited transforms) while snapshots keep the Canvas path. Both read the same `RigPose`.
- Part images are decoded once at load from the validated bytes (as `PackImageCache` does), about 1.5 MiB decoded per skin at 2×.

### 7.4 Clock, frame rate and idle cost

- One clock, unchanged: `TimelineView` dates plus `clockOffset`, the clip's `startedAt`. No timers, no physics state.
- `MascotView.redraw` keeps its shape: continuous (60 fps, or 30) only while a clip, drag, spring or marker burst runs; 8 fps for doze; otherwise `idleFrames`.
- **Idle stays as cheap as today.** At load, and when the accessories change, the engine bakes the idle rest pose for each idle face (4 images, plus 4 with the helmet when the marker shows) and the attention and urgent poses into `CGImage`s at the art's pixel size. Idle then draws exactly one baked image per `IdleFrameSchedule` entry: the same code path and cost as a frame pack (the ~0.8% idle CPU must not regress, and the existing `IdleRedrawTests` keep pinning it). The blink is that schedule's four entries.
- Reduce Motion: no clips, ever (as v1). States show their baked static pose with the first face. Hat, drag and doze substitutions show their baked static poses.

### 7.5 Layout: hover, lane and badge

- **Union.** At load the engine samples every state and clip at 60 Hz (about 1,000 samples per skin), takes each sample's transformed part outlines and builds the union outline. That is what `allContours`, `uprightContours` and `artProfile` use today, so lane height and hover placement come from the same code. Bundled rig packs must stay inside the skin's v1 union (validator); custom rig packs that exceed it get a taller lane or a wider hover offset, as custom frame packs do.
- **Badge.** The count tracks the current pose's top contour (section 7.2). The rig's contour changes continuously, so the count moves smoothly instead of jumping per frame. It is quantized to whole points to avoid shimmer.
- **Helmet and props** are part of every sample in which they show, so the union covers them.
- FX stay world-space sprites outside the contours, as v1.

### 7.6 Compatibility

- v1 and v2 packs (custom or old bundled) render through `PackFigure` exactly as today. Schema 3 only adds a branch.
- A v3 pack missing a clip behaves like v2 (no `new-item` → the #29 wave as a root-lean of the rest pose; no reaction or ambient clip → nothing).
- Settings, skins and the pack picker do not change. `latestSchemaVersion` becomes 3.

### 7.7 Tests (D2)

- Evaluator: key interpolation for each ease at exact milliseconds; `follow` and `sway` values; edge blends; clips end exactly on the hand-back pose.
- Timing: rig clip durations feed `ClipLibrary` and `EventClipQueue` like frame clips (new-item = 1900 ms).
- Bounds: placeholder rig clip samples stay within its union; the validator rejects an out-of-range key and a bone cycle.
- Reduce Motion: no clip pose, static baked pose only.
- Idle cost: `MascotView.redraw` for a rig pack at idle is `idleFrames` with the rig's blink schedule, never continuous.
- CPU: measured with `top`/`ps` on a `.rig138` build during a replayed `new-item` and at idle, reported with the numbers.

## 8. Open questions for PM

1. The engine smooths preemption with a 120 ms transform blend instead of v1's hard cut (section 5.2). Priorities and timing are unchanged. I think that is in the spirit of "no blend" (which existed because frames could not blend), but it is a change to a v1 rule.
2. 60 fps for 2-second clips is my default; I will report the measured CPU in D2 and drop to 30 fps if it is costly.
3. The rest pose is 4% smaller than idle-00 to give the head headroom inside the unchanged union. The alternative is to keep it full size and forbid any upward stretch, which makes perk-ups and hops much flatter.
