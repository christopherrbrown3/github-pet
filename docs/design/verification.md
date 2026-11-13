# Sprint 1 verification

2026-11-12, original saved pack after session restart. Graphic Designer role retained; Herdr restart launch arguments confirmed `gpt-6.1-sol`. No further image generation was needed after restart.

- `python3 -B docs/design/validate_pack.py --report`: pass. Twelve 256×256 RGBA files, all required states, safe paths, matching hashes, transparent borders, common baseline, bounded durations, loop flags and existing static fallbacks. Optional sheets and preserved source hashes also pass.
- All three exported sequence sheets visually inspected. Blink, wave and concerned gesture have distinct poses with preserved identity. Urgent source cell 3 is excluded because it contains unwanted motion marks.
- Five authored menu-bar SVG specifications parse as XML with a common 22×18 viewBox. All static image and document links in the review board resolve to saved files.
- Local HTTP Playwright review: 1200-pixel viewport, document scroll width 1200 (no horizontal overflow), all thirteen referenced images loaded. [Full-page desktop capture](review-desktop.png) inspected, including 64/128-point samples, light inbox, dark speech bubble and icon vocabulary. Browser snapshot and console log are preserved under `browser-evidence/`.
- Browser `file:` access was blocked; the board was rendered through a temporary loopback-only HTTP server instead. The HTTP console reported a missing favicon; this was not a pack image or script failure.
- `git diff --check`: pass before staging; staged files are checked again before commit.

Not verified: actual native app rendering, Developer's loader against the final pack, native resource bundling, VoiceOver, system Reduce Motion behavior, physical multi-display positioning, responsive board widths beyond the captured desktop viewport, or pixel-identical rebuilds across macOS versions. The review board's motion controls were not exercised in this final checkpoint. Contract timing is validated as metadata. Source contour variation is documented in provenance. These limits do not prevent independently building the runtime with its bundled placeholder.

## Copilot review fixes

On 2026-11-13, PR19 comments `4556164454` and `4556164506` were validated and fixed in the shared design tooling. The PNG reader now bounds input to 32 MiB, each dimension to 2048 pixels and area to 4,194,304 pixels before row allocation. Deflate output is limited to the exact expected RGBA scanline length plus one sentinel byte; truncated, overlong and concatenated streams are rejected. PNG hashing in the reader's direct callers is also bounded, and alpha bounds use constant extra memory. These limits cover the existing generated source sheets (1254×1254) and packed sheets (1024×256).

The pack validator now requires both the `alpha > 8` visible bottom and the `alpha > 0` bottom to equal the declared exclusive ground anchor. This rejects an upward-shifted frame even if its manifest hash is updated, rejects a faint pixel below the anchor, and prevents a faint anchor pixel from hiding a raised visible silhouette. It is a structural baseline check; semantic pose/character alignment still requires visual review.

`python3 -B -m unittest discover -s docs/design -p 'test_design_tools.py' -v`: 10 tests passed, including oversized and malformed headers, bounded compressed-bomb output, oversized files/hashes, truncated/concatenated streams, valid split IDAT, shifted frames with updated hashes, and legitimate full-pack validation. The original 1×1-header / 8 MiB decompressed bomb peaked at approximately 17.5 MB before the fix and approximately 214 KB afterward under `tracemalloc`; both rejected it, but the original rejection happened after the large allocation.

The existing pack validator, near-touch design validation and near-touch measurement tools also passed. A standalone temporary copy ran `build_pack.py` and `validate_pack.py`; every rebuilt pack file was byte-identical to the original. The checked-in generated assets were not modified. These tests cover the design tooling, not the separate application's runtime decoder or user-provided external pack handling.
