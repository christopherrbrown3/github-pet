# Mascot and native UI handoff

Sprint 1 design for [issue #3](https://github.com/christopherrbrown3/github-pet/issues/3). Scope: original companion artwork and implementation specifications. The review board is a browser-rendered design artifact, not the native application.

- Open [review.html](review.html) for the animation controls, size samples, inbox, hover preview and speech bubble designs.
- Runtime entry point: [`../../assets/mascots/mona-pet-v1/manifest.json`](../../assets/mascots/mona-pet-v1/manifest.json).
- [Native UI specification](native-ui.md), [generation provenance](provenance.md), [machine-readable checks](validation.json).
- [Native visual retests for #22/#23](reviews/pr18-088b678-3cf6fa7-retests.md), with exact reviewed commits and still-image limits.
- Validate: `python3 docs/design/validate_pack.py --report` from the repository root.
- Rebuild from preserved generated sources on macOS: `python3 docs/design/build_pack.py`. Python standard library and macOS `sips` only. This packs/resamples existing image-generated art; it does not synthesize replacement artwork. Runtime builds do not require these design scripts or image-generation access.

## Pack contract agreed with Developer

`schemaVersion: 1`, id `mona-pet-v1`, 256×256 RGBA PNGs, upper-left image origin, common ground anchor `[128,232]`. Scale the entire canvas uniformly with smooth interpolation; this is continuous-tone cartoon art, not pixel art. At a 128-point canvas the anchor is `[64,116]`; place that point at the saved desktop ground position. Changing state never changes the window bounds or anchor.

| State | Sequence | Duration | Loop | Reduced-motion fallback |
|---|---|---:|---|---|
| idle | four-frame blink | 4400 ms | yes | `frames/idle-00.png` |
| attention | polite wave | 1900 ms | no | `frames/attention-03.png` |
| urgent | calm concerned gesture | 1900 ms | no | `frames/urgent-00.png` |

Each state lists individual frame paths, `durationMs`, `loop`, and `staticFallback`. `frameSha256` covers all runtime frame files. Developer v1 reads individual frames; optional 1024×256 sheets and their row-major rectangles are recorded separately in `packing.json`. Three distinct urgent images form four timeline entries, with the first image repeated at the end to settle. Source urgent cell 3 has generator-added motion ticks and is deliberately excluded.

Validate paths inside the pack, dimensions, alpha, frame counts, bounds, duration range 125–2000 ms, fallbacks and hashes before use. On any failure use the runtime's independently bundled placeholder; a missing pack must not stop the inbox or app launch. Total decoded runtime frame data is 3,145,728 bytes if all twelve files are cached. Load only required frames, bound caches, and do no disk I/O on every animation tick.

Idle loops use monotonic time. New actionable/critical events play once, then settle to their fallback while the issue remains visible in the inbox. Unchanged polls preserve phase. Skip missed frames rather than queuing catch-up. Reduce Motion from either system or app freezes the appropriate fallback, suppresses motion effects, and preserves all labels/actions. Quiet hours and snooze suppress unsolicited clips and bubbles, not inbox visibility.

## Validation boundary

The committed report verifies real PNGs and metadata. All exported sequences were visually inspected. Minor contour and face-shape variation remains between generated poses; alignment corrects grid drift, not every contour. Browser review checks exported artwork and design layouts. Native rendering, resource loading in the final `.app`, keyboard navigation, VoiceOver, menu-bar placement on actual displays, and system accessibility settings require Developer/QA verification on the integration commit. No claim of official GitHub affiliation or endorsement is made.
