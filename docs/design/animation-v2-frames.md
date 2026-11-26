# Animation v2: frame sequences (#138)

Both skins animate with generated frame sequences. Codex paints each clip as a 4 × 4 sheet of 16
transparent frames (loops: 4 frames in the first row), starting on idle-00. `FrameBake` turns the
sheets into ordinary schema v2 frame clips, and the existing clip engine plays them. Sources and
generation records are in [provenance.md](provenance.md) ("Issue 138 animation sequences").

A cutout-rig engine was built and paused in favour of this approach after Chris compared the two; it
is kept on the `design/138-rig` branch and does not ship.

## 1. What plays

| Clip or loop | Trigger | Frames |
|---|---|---|
| `new-item` | a genuinely new item | 16 |
| `item-cleared` | a Needs-you row dismissed | 16 |
| `inbox-zero` | a fresh poll goes from items to verified empty | 16 |
| `poke`, `dizzy` | a click; five quick clicks | 16 |
| `drag` (loop), `drop` | dragging the pet; letting go | 4, 16 |
| `idle-look`, `idle-stretch`, `idle-fidget` | ambient, after quiet time | 16 |
| `doze` (loop) | 15 quiet minutes | 4 |
| `incident-start`, `incident-end` | a GitHub incident appears; resolves | 16, 14–16 |
| `incident-idle` (loop) | the helmet blink loop while an incident shows | 4 |
| `poke-incident`, `dizzy-incident`, `drop-incident`, `drag-incident` | the same reactions wearing the helmet | 16 (drag 4) |

Triggers, priorities, caps and gates are the clip catalog's (`ClipCatalog.v1`), unchanged by the art.

## 2. Incidents (Chris's rule)

The helmet is always painted into the frames. These packs have no accessory overlay, so no code path
can draw a second hat.

- `incident-start` plays once when the incident marker appears from none; `incident-end` plays once
  when a fresh reply says operational after the marker was shown. A second incident, an escalation or
  a reopen while the marker shows gets the marker burst only. Stale or failed status hides the marker
  (honest states), so the helmet goes with it and returns without `incident-start`.
- While an incident is active, `incident-idle` replaces idle, attention and urgent (Reduce Motion: its
  first frame). It blinks like the idle loop: eyes open 2000 ms, then half, closed and open at 125 ms.
- `new-item`, the urgent gesture, `item-cleared`, `inbox-zero`, ambient clips and doze give way to it.
- `poke`, `dizzy`, `drop` and `drag` still play, as their `-incident` helmet variants when the pack
  has them (it does for both skins), including the Reduce Motion drag still.
- A custom pack without `incident-idle` keeps the v1 behaviour (its clips play and its hat overlay is
  drawn).

## 3. Pipeline

`swift run -c release FrameBake assets/mascots/<skin>/frames-source.json [--clip <name>] [--preview <png>]`

- **Cells:** found by connected components (any sheet size), with props attached to the nearest
  character. `skip` drops cells (Mona's `incident-end` frames 12–13 had two helmets).
- **Registration to idle-00:** a clip's first frame is scaled to idle-00's height, or by the face for
  clips that start wearing the helmet (`registerBy: face`), so the helmet doesn't shrink the pet. Every
  later frame is held at that size by its face (Mona's face plate, Little Chris's skin), within 6% of
  the clip's median, which removes the generator's zoom drift. The face centre aligns x and the lowest
  pixel sits on idle-00's ground row.
- **Frame 1 is idle-00 itself** (`firstIsReference`), referenced rather than copied.
- **Clean-up:** faint fringe and specks are dropped.
- **Bounds:** each frame is checked against the skin's art union, measured exactly as the loader does.
  With `fit`, a clip is shifted, then scaled uniformly about the ground anchor until it fits, and
  shrinks further if the count's lane would grow.
- **Nozzle:** `incident-end`'s spray frames (`nozzleFrames`) get `nozzle` points for the mist.
- **Size:** near-identical consecutive frames merge into longer frames (`dedupe`); `quantize` writes
  256-colour palette PNGs with alpha. The quantizer is deterministic: a rebake writes the same bytes.
- **Output:** v2 clips and loops in the pack's manifest, checksums for the images in use, and stale
  frames from earlier bakes of a clip removed.

## 4. Engine

- 16 frames per clip; clip frames 40 to 2000 ms (states keep 125 ms); `poke` and `drop` caps 1200 ms;
  bundled budget 256 images and 16 MiB.
- 60 fps while a clip with frames under 100 ms plays; 30 otherwise; idle redraws only on frame changes.
- **The count's slot and tracking range come from the states** (idle, attention and urgent, plus the
  attention lean), not from clip frames, so a clip pose that reaches past the head or ducks lower never
  moves the count. The drag and dizzy lean is limited so its sweep never makes the lane taller.
- Bundled packs: the lane, slot and count range equal `main`'s at every size.

## 5. Size

| Packs (both skins, staged in the app, on disk) | Size |
|---|---|
| `main` (v1 frames) | 0.93 MB |
| Sequences, PNG as generated | 17.0 MB |
| + end-hold dedupe and idle-00 reuse | 16.2 MB |
| **+ 256-colour palette quantization (shipped, 481 frames)** | **7.6 MB** (+6.7 MB) |

PNGs don't compress further, so the app download grows by the files' 6.2 MB. At 64, 128 and 256 pt @2x the quantized frames can't be told apart from the originals. Frames stay
256 px: the mascot is up to 256 pt (512 px at 2×), so smaller frames would blur at the larger sizes.

## 6. Dev and QA hooks

Both are ignored under the production bundle ID.

- `--replay-clips <secs>`: plays the pack's clips in turn through their real paths, without touching
  data. While an incident shows it cycles only the clips that play over the helmet loop.
- `--dump-incident-frames <dir>`: draws every frame of every situation during an incident for both
  skins with the app's own animator and renderer, reports overlays drawn (must be 0) and helmets
  counted, and writes one contact sheet per skin. Fixtures and in-memory preferences; quits when done.
