# Compact badge spacing: measured revision to #28

Chris's newer direction supersedes the earlier 28/36/48-point lane heights. Keep the approved badge typography, sizes, measured label widths, full DEMO, truthful counts and non-overlap. Bring labels close to the **visible opaque character**, allowing the labels to enter the transparent margin of its canvas. These are design targets for Developer; they do not assert a runtime fix.

| Art side S | Panel W × H | Art top L | Count H / SF font | Full DEMO / `99+` width | Conservative visible-top clearance |
|---:|---|---:|---|---|---:|
| 64 pt | 96 × 83 pt | 19 pt | 20 / 12 pt | 39 / 36 pt | ≥ 3.25 pt |
| 128 pt | 128 × 151 pt | 23 pt | 28 / 16 pt | 46 / 47 pt | ≥ 3.5 pt |
| 256 pt | 256 × 282 pt | 26 pt | 40 / 22 pt | 54 / 62 pt | ≥ 3 pt |

Coordinates are points from the panel's **top-left**, x right and y down. The count capsule's top is `y=0`; its trailing edge is inset 4/6/8 points at 64/128/256. Full DEMO starts at the corresponding leading inset and is vertically centered against the count (DEMO top y=2/4/8; height 16/20/24). Measured SF widths put the 99+ capsule at x=56/75/186 and DEMO at x=4/6/8; horizontal separation remains 13/23/124 points. `2+`, `?`, and shorter exact counts fit inside the widest reserved count allocation. No label is truncated or shrunk. Use contrast-aware native fills and accessible labels per the original specification.

The S×S artwork canvas starts at `x=(W−S)/2, y=L`; at 64 this is x=16, not x=0. **Do not clip either label to the art rectangle:** count enters the transparent art canvas by 1/5/14 points at the three anchors, while remaining above the earliest visible opaque pixel. The panel's ground anchor remains `[W/2, L + 232×S/256]` in top-left coordinates, equivalently `[W/2, 24×S/256]` in AppKit bottom-left coordinates. Preserve that point in screen coordinates while resizing the panel. No artwork scaling beyond the existing S×S size and no window jump on badge text changes.

## Derivation and limits

The original pack's 12 RGBA frames were re-read with `alpha > 0`. Their upright visible alpha tops are 20–25 source pixels: idle 22–23, attention 25, urgent 20. The previous design validation conservatively bounded each attention frame's full alpha rectangle across the proposed ±5° sway, sampled every 0.1°; the earliest sampled bounding top was **17.94** source pixels. Using **17** as the floor adds at least 0.94 source-pixel margin. The maximum unsampled angular change within half a 0.1° step is under 0.21 source pixels for these bounding corners, leaving margin for continuous interpolation. The conservative result covers all current upright idle/attention/urgent frames and the proposed attention sway. It does not assume the more optimistic 19-pixel point found by Developer's pixel sweep.

At each target size, earliest art top ≥ `L + 17×S/256`. The count bottom is its height. The revised L values therefore give ≥3.25, ≥3.5 and ≥3 points respectively. This is an art-to-label **bounding clearance**, not a claim that the actual nearest glyph-to-ear pixel is exactly that distance. DEMO is shorter than the count and has at least the same vertical clearance. Keep capsule/shadow drawing inside the specified rectangles, or include any outward shadow in the clearance calculation.

For intermediate S in 64…256, interpolate the existing count height and type/padding metrics as previously specified, round dimensions up to whole points, then use `L = max(0, ceil(countHeight + 3 − 17×S/256))` for this pack and sway. Preserve `W = max(S, 96, measured full DEMO + widest count + 2×inset + minimumGap)`, reserving `99+` even for `?` or `2+`. Keep L/W stable across value, privacy and mood changes. If an accessibility text override grows a capsule, recompute L/W from actual measured capsule bounds and retain the 3-point minimum; do not truncate.

The source-pixel floor is **pack-specific**. A different pack, edited frame, larger rotation, extra badge shadow, changed transparency or different animation must calculate a new all-frame/all-pose opaque envelope, with a conservative interpolation margin. If it cannot guarantee clearance, keep the labels outside the art canvas until the envelope is known. Unknown, partial (`2+`), capped `99+`, DEMO, privacy, quiet/snooze and reduced-motion semantics remain as in [the main handoff](README.md).

PM's chosen hover direction remains beside the character, right by default and left at the right screen edge. The #27 requirement is **0–12 points maximum gap without art/tag overlap**, not a mandatory 12-point minimum. The smaller panel and optional #29 sway change the geometry; Developer must recalculate and QA must verify placement at all sizes/edges. Keep hover content compact at the small size (maximum two lines, preserving count and quality), and follow PM's existing upright/clip start-end anchor adjustment direction. This document does not change runtime behavior or certify native screen placement.

## Evidence and handoff

Input: original generated `mona-pet-v1` frames and [existing validation](design-validation.json), which reports the sampled conservative sway bounds and verifies all 12 source frame hashes. Previous standalone AppKit SF measurements remain valid because count/demo dimensions and fonts are unchanged; only the proposed lane height changes. The older comparison images intentionally remain historical and **do not depict this compact revision**. The anchor/gap table above is a computed design proposal; Developer/QA should capture the actual revised native UI and verify full labels, alpha clearance in every state, rotation endpoints/intermediates and changed screen edges. No new artwork, runtime code, board change or merge was made for this revision.

On 2026-11-13 the Designer checked all 12 upright alpha bounds, the earlier attention-sway envelope, the three panel dimensions, widest-label horizontal fit, anchor coordinate conversion and the conservative gap formulas. All three calculations passed. No native rendering of the compact revision or live screen-edge test is claimed.
