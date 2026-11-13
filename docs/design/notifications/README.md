# Responsive badges and a clearer new-item gesture

Design handoff for [#28](https://github.com/christopherrbrown3/github-pet/issues/28) and [#29](https://github.com/christopherrbrown3/github-pet/issues/29). The existing generated mascot identity and pack remain intact. These are reviewable implementation specifications; Developer owns the later application changes after PM handoff and #27 completion.

- [Light badge comparison](badges-light.png) and [dark comparison](badges-dark.png): standalone native AppKit compositions, with actual SF font measurements and art at 64/128/256 points. Each row includes `2`, `2+`, `?`, `99+` and DEMO. Thin panel outlines are review guides only.
- [Attention storyboard](attention-keyposes.png) and [playable size comparison](preview.html): seven key poses, finite 1900 ms timeline, existing generated frames with a bounded art-layer sway.
- [Badge dimensions](badge-metrics.json), [attention timing](attention-storyboard.json), [native font measurements](native-measurements.json), [validation/provenance](validation.md).

## #28: responsive count badge

| Art square S | Count height | Count SF semibold | Count horizontal inset per side | DEMO height / SF bold / inset | Label lane L | Panel W×H |
|---:|---:|---:|---:|---|---:|---|
| 64 pt | 20 | 12 | 6 | 16 / 9 / 5 | 28 | 96×92 |
| 128 pt | 28 | 16 | 8 | 20 / 11 / 6 | 36 | 128×164 |
| 256 pt | 40 | 22 | 10 | 24 / 13 / 7 | 48 | 256×304 |

Use SF monospaced digits at semibold weight for the count; punctuation uses the same font. Capsule width is `max(height, ceil(measuredTextWidth) + 2×horizontalInset)`. Capsule radius is half its height. The count has a minimum readable 20-point height at the smallest art size and visibly grows to 40 points at the largest; do not scale down a 256-point composite bitmap. Generate labels with native text at each display's backing scale. No badge movement/pulse is needed.

DEMO is a separate leading capsule; count is trailing, both vertically centered in the lane. Horizontal panel insets are 4/6/8 points; minimum gaps between capsules are 6/8/12 points. Actual SF measurements in the saved comparisons give `99+` count widths 36/47/62 points and DEMO widths 39/46/54 points. The tightest gap is 13 points at size 64, above the 6-point minimum. Neither label touches the character, even at the widest count.

For sizes between anchors, linearly interpolate metrics separately over 64–128 and 128–256, rounding dimensions up to whole points. Measure text after rounding; use `L = countHeight + 8`, and `W = max(S, 96, 2×panelInset + measuredDemoWidth + widestCountWidth + minimumGap)`. `widestCountWidth` is computed from `99+` even when displaying a shorter label. This accommodates intermediate font widths and avoids count-driven window jitter. Keep the same panel dimensions when DEMO is absent, count changes, privacy toggles or mood changes. A text accessibility override may expand W/L to preserve readability; never clip or shrink labels to make them fit.

The art remains S×S and centered horizontally below the lane; it is not stretched to the wider 96-point minimum panel. In top-left design coordinates the art origin is `[(W−S)/2,L]`; its common pack anchor is `[W/2,L + 232×S/256]`. In AppKit bottom-left coordinates the art origin is `[(W−S)/2,0]` and the ground point is `[W/2,24×S/256]`. When resizing a saved panel, preserve that world-space ground point; compute the new window origin from it. Window height is `H=S+L`. Thus the 64-point design adds label space without lifting, cropping or enlarging the character. All labels are outside the art square. Frame choice and the proposed attention transform do not affect these bounds.

After Developer integrates this with #27, clamp the full revised panel to the display work area. Keep hover anchored to the art/visible-art geometry, not the enlarged label lane or window center. Re-evaluate arrow clearance and screen-edge behavior with the new dimensions; the previous hover geometry checks do not prove the revised panel works on screen. No hover-placement code or approval is supplied by these comps.

### Truthful labels and privacy

`2` is an exact fresh known count; `2+` means at least two items in partial results. `?` is unknown/loading/stale/error, never a fabricated zero. `99+` is a compact cap: a fresh exact value above 99 is capped; a partial lower bound of 99 or more can also display `99+`. Preserve the underlying quality distinction in text and accessibility labels. An exact 99 remains `99`; unknown always wins over truncation. Never render an unbounded four-digit pill. Disabled sources remain “Not monitored,” excluded from totals rather than counted as zero.

Accessible names retain the uncapped value/qualifier, for example “123 items,” “at least 123 items, some sources unavailable,” or “count unknown, loading.” The visual badge shows the current total, not a temporary new-event count. New-item wording belongs in the shared inbox or existing bubble. DEMO remains explicit for fixtures at every size and has no real-data counterpart. Privacy keeps counts, urgency, quality and DEMO visible while repository/title/account information remains hidden. Do not add hidden names to tooltips or accessibility labels.

The comparison uses white text on a dark blue fill in light appearance and black text on pale blue in dark appearance, with reversed neutral DEMO capsules. Developer should use appearance-aware semantic roles with a minimum 4.5:1 text/fill contrast, including accent changes. Urgency still needs words/symbols; color is supplementary. The existing black art has reduced silhouette separation on dark backgrounds; these badge comps do not certify or revise the separate art-contrast treatment.

## #29: friendly double wave, finite 1.9 seconds

The existing clip holds four similar poses for 300/400/400/800 ms, with only one small limb gesture. Preserve the original art and make the action more legible by reusing its poses twice while adding a smooth ±5° lean around the common ground anchor. The head's lateral travel helps the cue remain visible at 64 points. No new raster artwork is required for this proposal. It requires Developer to implement a bounded rotation on the art layer; the existing v1 PNG loader does not interpret the design JSON and is not changed here.

| Time | Existing attention frame | Art rotation target | Action |
|---|---|---:|---|
| 0–150 ms | 00 | 0° | brief notice/lead-in |
| 150–400 | 01 | −5° | lift limb, lean left |
| 400–600 | 02 | +5° | wave inward, lean right |
| 600–850 | 01 | −5° | second outward wave |
| 850–1050 | 02 | +5° | second inward wave |
| 1050–1300 | 03 | 0° | settle upright |
| 1300–1900 | 03 | 0° | stable hold, finish |

Angles are reached at the listed start times by continuous interpolation from the preceding target, using cubic Bezier `(0.2,0.8,0.2,1)` over the preceding interval. The last 600 ms are still. Frame changes occur at the listed boundaries; no crossfade, scaling, transparency, brightness pulse, confetti or window movement is needed. At most one art-layer motion is active. All art remains inside the original 256×256 canvas; rotate within that fixed viewport around `[128,232]`, scaled to S. Labels, count, inbox, bubble text and the native window remain stationary. The preview uses the same path/timing/pivot. The timeline explicitly ends; `loop=false`.

This is a design proposal for increased salience, not a measured detection/noticeability claim. At 64 points the motion is intentionally modest and benefits from the fixed readable count plus existing bubble. If the runtime cannot provide smooth bounded rotation, the requested more-obvious gesture is not delivered by changing durations alone; PM should choose between supporting that layer animation or commissioning more distinct generated poses. Do not silently replace the art with procedural character drawings.

For #27 integration, a rotating pose can rise above its static visible-art top even while staying within its canvas. Use a stable conservative envelope of the active clip's transformed art when placing a hover/bubble; do not assume the static 2-point clearance also clears every tilted pose, or move the bubble on every frame. The saved bounds report gives a conservative top near 17.94 source pixels across the proposed frames/angles. This requires later native placement checks with actual arrow/chrome at all sizes and edges.

### Event and accessibility invariants for implementation

- Trigger only genuinely new events from a comparable fresh source snapshot after an established baseline, using stable IDs and meaningful revisions. First sync, account/scope baseline, unchanged polls, noncomparable recovery and viewing old inbox items do not trigger the cue. This design does not redefine event eligibility.
- One snapshot with multiple new items produces one gesture, one existing generic summary/bubble and the updated total. New eligible items arriving during the gesture merge into that summary without restarting or queuing rapid waves. After it finishes, a separate later genuinely new batch may use the normal trigger policy. Never play a backlog of missed clips. Urgent events can preempt according to existing priority; do not replay interrupted attention afterward.
- System or app Reduce Motion selects `attention-03.png`, 0° immediately, with no rotation, pose cycling or other motion. A new cue does not override it; enabling it mid-clip cancels motion and settles immediately. Labels and inbox visibility remain. Static fallback pose remains a visible attention state, independently of transient animation eligibility.
- Existing quiet-hours and snooze rules continue to suppress unsolicited animation/bubbles. Count/inbox updates still occur. Do not replay suppressed events on expiry. Entering quiet/snooze during a clip cancels it and leaves the proper static state; opening the inbox or hovering never starts a gesture.
- Unchanged snapshots preserve idle phase. A completed attention cue returns to the state selected by the app; it does not clear items or replace urgent state. Drive deadlines with monotonic time; skip late frames, keep one active clip, stop timers when inactive, and avoid disk I/O per tick.

## Provenance and integration boundary

All character pixels come from the already generated `mona-pet-v1` frames and source provenance; no image-generation call or asset revision was needed for these two tasks. Badges are native text/geometric UI, and the wave is an art-layer transform of those original images. `manifest.json`, pack PNGs, hashes and anchor remain unchanged. The new JSON files are design inputs, not a new runtime pack format. Native comps were rendered with the standalone [AppKit script](render-comparison.swift), with no import or modification of `Sources/`. The HTML is a review tool only. This work makes no GitHub endorsement claim.

Developer handoff after PM approval/#27: implement responsive metrics + stable panel geometry (#28), then the finite art-layer timeline/coalescing (#29), with native captures at all three sizes and real display edges. Verify event-baseline, concurrent arrivals, Reduce Motion, quiet/snooze transitions and urgent preemption. Designer's visual comps and metadata checks cannot prove those runtime behaviors.
