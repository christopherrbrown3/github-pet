# Sprint 1 verification

2026-11-12, original saved pack after session restart. Graphic Designer role retained; Herdr restart launch arguments confirmed `gpt-6.1-sol`. No further image generation was needed after restart.

- `python3 -B docs/design/validate_pack.py --report`: pass. Twelve 256×256 RGBA files, all required states, safe paths, matching hashes, transparent borders, common baseline, bounded durations, loop flags and existing static fallbacks. Optional sheets and preserved source hashes also pass.
- All three exported sequence sheets visually inspected. Blink, wave and concerned gesture have distinct poses with preserved identity. Urgent source cell 3 is excluded because it contains unwanted motion marks.
- Five authored menu-bar SVG specifications parse as XML with a common 22×18 viewBox. All static image and document links in the review board resolve to saved files.
- Local HTTP Playwright review: 1200-pixel viewport, document scroll width 1200 (no horizontal overflow), all thirteen referenced images loaded. [Full-page desktop capture](review-desktop.png) inspected, including 64/128-point samples, light inbox, dark speech bubble and icon vocabulary. Browser snapshot and console log are preserved under `browser-evidence/`.
- Browser `file:` access was blocked; the board was rendered through a temporary loopback-only HTTP server instead. The HTTP console reported a missing favicon; this was not a pack image or script failure.
- `git diff --check`: pass before staging; staged files are checked again before commit.

Not verified: actual native app rendering, Developer's loader against the final pack, native resource bundling, VoiceOver, system Reduce Motion behavior, physical multi-display positioning, responsive board widths beyond the captured desktop viewport, or pixel-identical rebuilds across macOS versions. The review board's motion controls were not exercised in this final checkpoint. Contract timing is validated as metadata. Source contour variation is documented in provenance. These limits do not prevent independently building the runtime with its bundled placeholder.
