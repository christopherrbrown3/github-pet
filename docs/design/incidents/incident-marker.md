# GitHub incident marker (#37)

A separate marker for a confirmed, unresolved GitHub service incident (#11). It is funny but hard to miss: a siren for every incident, flames for major ones, and flames plus billowing smoke for critical ones. The marker never changes the count badge, which still counts actionable items only.

The machine-readable spec is [`incident-marker.json`](incident-marker.json). developer-2 transcribes it into Swift constants, and a unit test reads the json so the two cannot drift. Keep key names stable and values as plain numbers. The siren glyph is [`assets/mascots/mona-pet-v1/ui/incident-siren.svg`](../../../assets/mascots/mona-pet-v1/ui/incident-siren.svg). It uses the same coordinates as the json, with the light palette.

## Route

The marker is procedural (route B): flames, smoke and the beacon sweep are drawn natively from parameters, so they animate at any size, switch palette in dark mode and need no new raster pipeline. The siren is the one hand-authored vector piece. We need no image-generation artwork. If the flat vector fire looks wrong next to the painted mascot in live review, painterly art can be reconsidered then.

## When it shows

| Incident state | Marker |
|---|---|
| Fresh, unresolved, impact `none` or `minor` | minor |
| Fresh, unresolved, impact `major` | major |
| Fresh, unresolved, impact `critical` | critical |
| No unresolved incident; component-only `degraded_performance`; maintenance; resolved | none |
| Stale status, failed fetch, loading | none; these keep their own unknown/stale indicators |

## Tiers

- **minor:** the siren, its glow and a rotating beacon sweep.
- **major:** the minor layers plus six flame tongues (three at 64 pt) along the ground behind the mascot. At every size the tallest tips stay at or below canvas y 142.
- **critical:** taller flames (tips at or below y 88 at every size) plus smoke rising from both flanks (top edge at or below y 70).

## Geometry

Units are the 256-unit art canvas, with the origin at the top-left of the S×S art square and y pointing down. One unit is S/256 points.

The marker is drawn in world space and anchored to the ground. It does not rotate with the #29 sway. It uses the existing panel and does not grow it or move the ground anchor.

Measured from the mona-pet-v1 frames, the mascot occupies x 51–211 and y 20–231 in every pose. The marker lives in the free space:

- **Siren:** bottom-left, x 10–46 and y 202–248. That is diagonally opposite the count badge.
- **Flames:** along `baseY` 246, visible on both flanks and between the tentacles.
- **Smoke:** rises from both flanks, x roughly 0–60 and 196–256.

Layer order, back to front:

1. beacon sweep
2. smoke
3. flames
4. siren
5. mascot art
6. DEMO and count labels

### Keep-out

No marker pixel may appear:

- above canvas y 64, the label lane plus the top quarter of the art square;
- within 2 pt of the DEMO rect;
- within 2 pt of the full reserved `99+` count slot.

The count text also carries the data-quality signal (`2+`, `?`), so this protects it too. The native renderer also clips every layer below the live label zone. Even so, the shapes are designed so that the clip never shows.

`render-incident-preview.swift` draws every tier unclipped at 64, 128 and 256. It checks the static frame and 180 burst frames (6 s at 30 fps) for the topmost marker row:

| Tier | Topmost row | Keep-out |
|---|---|---|
| minor | y 94 | PASS |
| major | y 94 | PASS |
| critical | y 70 | PASS |

Before any `99+` badge or DEMO label is drawn, there are at least 6 units of clearance. Hover keeps measuring its #27 gap to the mascot art only. When the hover popover flips left at the right screen edge it may cover the siren; PM accepted this.

### Small sizes

At 64 pt:

- **Flames** simplify to three wider tongues, with only the outer and core layers.
- **Smoke** puffs keep a radius of at least 12 units (3 pt), with three per emitter.
- **Siren** stays at about 10 pt.
- **Side gutters:** the 16 pt panel gutters are available but not used by default.

## Motion

- **Burst:** about 6 s at 30 fps:
  - 300 ms opacity fade-in from 0, eased with `cubic-bezier(0.2,0.8,0.2,1)`. Flame heights are not scaled. For a new incident every layer fades in, including the siren. On a tier rise only the newly added layers fade in, and layers already shown stay fully opaque, so the siren never blinks out;
  - full motion;
  - a 600 ms crossfade to the static frame, with no snap.
- **What starts a burst:**
  - first confirmation of a new unresolved incident;
  - any upward tier change of a known open incident: minor→major, minor→critical or major→critical. It plays once per tier reached for that incident id.
- **What stays silent:**
  - tier drops;
  - reaching a tier again that the incident already reached (critical→major→critical);
  - reopens;
  - baseline at first sync or after an account/scope change;
  - a noncomparable reconnect;
  - an unchanged poll.

  A marker that is already active at baseline appears static.
- **Flames:** shape only. Height and lean follow two sines (0.42 s and 0.61 s), with a 0.9 s lean. Colors and alpha stay constant, so nothing flashes.
- **Smoke:** puffs live for 2.4 s and are staggered 600 ms apart. They drift up and outward, grow from 10 to 24 units and fade linearly. Each puff is a three-lobe soft cluster.
- **Beacon:** one clockwise sweep every 1.2 s. It is a 36° wedge with radius 120 and feathered edges. The radius means it never reaches the keep-out band.
- **Suppression:** under Reduce Motion (system or app), quiet hours or snooze, the static frame is drawn immediately. If one of them starts during a burst, the burst is cancelled with no crossfade. The marker always stays visible.
- **Other gestures:** the burst does not trigger the #29 mascot gesture and runs independently of it.

## Static frame

The static frame is used under Reduce Motion, quiet hours and snooze, after a burst, and at baseline:

- the siren lit with its glow;
- the beacon frozen at −100°, pointing up the left margin, away from the count, at alpha 0.34;
- the tier's flames at 0.93 of their height with no lean;
- critical smoke as four still puffs at 0.8 alpha.

It has the same footprint as the animated marker, so there is no layout shift.

## Color and contrast

The palette has light and dark tokens. Every drawn alpha is the token alpha × the layer's alpha scale × the burst envelope.

The panel floats over any wallpaper, so:

- the outer flame always carries a 1 pt darker rim;
- the siren carries a near-black outline at least 1 pt wide;
- smoke is a darker grey in light mode and a lighter grey in dark mode.

The orange flames and red glow also outline the black mascot. That improves its known low contrast in dark mode while an incident is shown.

## Accessibility

- **Hover:** the top line reads `GitHub incident: <name>`.
- **VoiceOver and menu-bar label:** `N items, 1 active GitHub incident`.
- **Privacy:** privacy settings apply as elsewhere.

## Previews

The `previews/` folder holds design previews. They are not native MascotView renders and not live desktop captures, and DEMO and the count label are not drawn in them.

`render-incident-preview.swift` draws the json with CoreGraphics behind real mona-pet-v1 frames:

- **Frames:** `attention-03` for minor; `urgent-00` for major and critical.
- **Sizes:** 64, 128 and 256 pt.
- **Appearance:** light and dark.
- **Scale:** 2× pixels.
- **Columns:** static, then burst at 0.05 s (mid fade-in of a new incident), 1.2 s and 2.6 s.
- **Rows:** minor, major, critical.

`incident-128-light-keepout.png` outlines the lane plus the y < 64 keep-out band in blue. These are still images, so they show neither motion quality nor timing. Live QA must judge both with Reduce Motion off.

Regenerate:

```sh
swift docs/design/incidents/render-incident-preview.swift "$PWD" docs/design/incidents/previews
```
