# Little Chris

Little Chris is a selectable mascot skin designed for [issue #83](https://github.com/christopherrbrown3/github-pet/issues/83). The character pairs an expressive face and warm brown hair with a navy hoodie, tan trousers and sneakers. Idle is a soft blink, attention is a left-side wave, and urgent presents an open hand to the right before settling. The inbox and status markers carry the meaning of an event.

## Source and rebuild

The PM supplied the original 1254 × 1254 RGBA pose sheet generated with built-in ImageGen from the references in issue #83. The [unaltered source PNG](../../assets/mascots/little-chris-v1/source/little-chris-poses.png) has SHA-256 `a87cd707e04e8f06ee110dab68d6d176e46ba459163ed317ccab33c32d1128b1`. Reference images and attachment identifiers stay with the issue.

Run `python3 -B docs/design/build_little_chris_pack.py` on macOS. The helper uses the repo's RGBA PNG reader and writer and macOS `sips`. It checks the source digest, slices the sheet row-major into 418 × 418 cells, and applies one 236/418 scale to all nine. Source silhouettes are 375–376 px tall at alpha greater than 8. Unfiltered haze reaches some cell borders. Pixels at alpha 0–8 (at most 3.14% coverage) are zeroed in the working copy before resampling. The brighter contour lies entirely within each cell. The builder centers the bottom eight solid shoe rows horizontally and places the exclusive bottom of the resampled alpha at y = 232. It rejects any pose whose nonzero pixels would enter the outer eight canvas pixels.

## Runtime handoff

The pack root is `assets/mascots/little-chris-v1/`. Bundle only [manifest.json](../../assets/mascots/little-chris-v1/manifest.json) and the nine relative PNG paths below. The source sheet, helper and previews are design inputs. The manifest declares schema v1, pack ID `little-chris-v1`, display name `Little Chris`, 256 × 256 RGBA canvas and anchor `[128, 232]` in upper-left coordinates.

| State | Runtime frame paths in order | Frame durations (ms) | Playback | Static fallback |
| --- | --- | --- | --- | --- |
| Idle | `frames/idle-00.png`, `frames/idle-01.png`, `frames/idle-02.png` | 2000, 125, 125 | 2250 ms loop | `frames/idle-00.png` |
| Attention | `frames/attention-00.png`, `frames/attention-01.png`, `frames/attention-02.png` | 350, 600, 350 | 1300 ms once, within the 1900 ms event clip | `frames/idle-00.png` |
| Urgent | `frames/urgent-00.png`, `frames/urgent-01.png`, `frames/urgent-02.png` | 300, 900, 500 | 1700 ms once, within the 2000 ms event clip | `frames/urgent-02.png` |

The loader accepts a shared static fallback, so attention can settle to the neutral idle pose. Three attention frames use the manifest timeline. The runtime's four-frame double wave and lean require at least four attention frames. Both event sequences hold their final frame through the rest of the active clip. In Reduce Motion, the neutral poses keep the character in a relaxed stance.

## Review evidence

- Reviewed all nine PNGs in row-major playback order on four contact sheets. Idle, attention and urgent occupy the first, second and third rows. The face and gestures remain distinguishable at 64 px. The hoodie has lower contrast against the dark backdrop, while the face, hands and soles stay visible. [64 px light](reviews/little-chris-83-64-light.png) · [64 px dark](reviews/little-chris-83-64-dark.png) · [128 px light](reviews/little-chris-83-128-light.png) · [128 px dark](reviews/little-chris-83-128-dark.png)
- All nine files decoded as RGBA8 with transparent padding and distinct SHA-256 checksums matching the manifest. Source and runtime digests matched before and after a second rebuild on this Mac. The manifest and nine PNGs total 434,823 bytes. Manifest SHA-256 is `a44a4de4be7be54b34cfd7658f21957a05a5cc28b22625cc39352700c8f469ce`.
- Across all nine canvases, the union of nonzero alpha bounds is `[62, 19, 206, 232)` (exclusive right and bottom). The solid sole bottom is y = 231 exclusive in every frame, and measured shoe centers range from x = 127.5 to 128.0. The upper silhouette center spans 2 canvas pixels, or 0.5 px at a 64 px display size. The hair and features retain small shape differences from the original poses.
- A standalone Swift check compiled the core sources at `00e1be4` and called `MascotPack.load` on the finished asset directory. ImageIO accepted all nine files, the loader produced three frame contours plus a fallback contour per state, and the fallback selections and attention manifest timing matched the handoff.
- Final bundle inclusion, selection and persistence, native motion and badge clearance, and system Reduce Motion remain integration checks for Developer and QA.
