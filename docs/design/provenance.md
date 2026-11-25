# Artwork provenance

Generated on 2026-11-12 using the built-in `image_gen.imagegen` integration under the imagegen skill. The orchestration terminal was launched with `gpt-6.1-sol`; the image integration does not expose its image-model identifier. No alternative model, procedural mascot, downloaded Octocat artwork, official GitHub logo, or credential was used.

The first approved capability probe is preserved byte-for-byte as `sources/probe.png` (SHA256 `62eba55c827cfc1fdf355069a2239fc41afec370995b6ec38933cf8fdadb9fe2`). Three image-edit calls referenced that exact probe with `transparent_background: true`. Original generated 1254×1254 RGBA source sheets remain unchanged under `assets/mascots/mona-pet-v1/sources/`. Their hashes are in `packing.json`.

| Source | Generation artifact identifier | Prompt intent |
|---|---|---|
| probe.png | exec-1de16c8d-f068-4e70-ac0a-b031e2520956 | One original friendly black Mona-inspired cat-octopus, cream face, gray highlights, waving limb, full body, transparent background |
| idle-sheet.png | exec-e0efaee6-6818-4b7d-813d-cd226ec73945 | Preserve exact probe identity; 2×2 four-frame idle sequence: eyes open, half closed, blink, open with tiny tentacle curl; fixed camera and baseline, transparent padding, no text/props |
| attention-sheet.png | exec-04e77441-5115-4457-8f85-2c4d620e632c | Preserve identity; 2×2 one-shot polite wave: limb partly raised, higher, curled inward, settled half-raised; locked torso/eyes, transparent background, no alarm |
| urgent-sheet.png | exec-386d465e-df8d-4cf6-94eb-64eef191857c | Preserve identity; 2×2 calm concern: limbs outward, gently raised, lowering, settled; kind eyes and concerned brows, no fear/tears/flashing, transparent background |

These are prompt summaries. Every generation requested equal quadrants, matching head scale/local position, generous transparent margins, no grid lines, lettering, watermark, background or cast shadow. Sources demonstrate the actual generated output, including imperfections: idle retains a raised limb despite the relaxed-pose request; urgent cell 3 includes unrequested motion ticks. Cell 3 is excluded from runtime urgent frames; no hidden retouching of that cell was performed.

`build_pack.py` extracts source quadrants, removes near-invisible stray alpha ≤8, resamples existing pixels through macOS `sips`, aligns the cream face horizontally and the lowest tentacle to a common baseline, and exports deterministic metadata, RGBA frames and review sheets. It never draws or synthesizes character features. All transformations and source bounds are recorded in `packing.json`. Minor contour differences remain between generated poses. Menu-bar SVGs are separately authored geometric inbox symbols, not generated mascot substitutes.

Visual review covered the original probe, all generated sheets and all exported runtime sequences. `validation.json` records actual dimension, alpha, padding, hash and timing checks. Native app integration and accessibility testing are not represented by these asset checks.

This is an independent Mona-inspired companion concept, not an official GitHub asset or endorsement. It is not offered as the app's product/logo mark. GitHub's [logo policy](https://docs.github.com/en/site-policy/other-site-policies/github-logo-policy) and [Octodex usage information](https://octodex.github.com/faq/) remain relevant to any distribution decision; generation alone establishes no trademark permission or clearance.

## App icon, painted (#88)

Generated using the built-in `image_gen.imagegen` integration; the image model identifier is not exposed. Each output was resized to 1024 × 1024 with `sips`, preserving alpha. `painted-b-inbox.png` is the source of the shipped app icon (see the clean-master section below); `painted-a-portrait.png` and `painted-c-envelope.png` are unshipped design explorations.

Reference SHA-256: Mona probe `62eba55c827cfc1fdf355069a2239fc41afec370995b6ec38933cf8fdadb9fe2`; Mona idle frame `79bacd0b3040edaa3708f05f322390604dba871e2374b909102f18fd6b9ff7cb`; current icon `5a669b09b796028f75ab8f275341d179a33f87836dd394d374c36b596b989103`.

| Master | Generation artifact ID | Prompt intent | References |
|---|---|---|---|
| `app-icon-88/painted/painted-a-portrait.png` | `exec-e9642d31-b40d-4f0a-a253-e54aa52cb6d4` | Large centered painted Mona portrait and upper tentacles on a blue macOS tile, transparent outside, readable at 32 px; no text or official marks. | Probe, idle frame, current icon (hashes above) |
| `app-icon-88/painted/painted-b-inbox.png` | `exec-b185edc5-2b4a-475a-bed7-255a1b21d4f7` | Painted Mona peeking over a rounded inbox tray on the blue tile, face unobstructed and readable at 32 px; no text or official marks. | Probe, idle frame, current icon (hashes above) |
| `app-icon-88/painted/painted-c-envelope.png` | `exec-ae304e7c-9984-4d2f-ad53-16451d2bf922` | Painted Mona holding a cream envelope with pale blue seal on the blue tile, face unobstructed and readable at 32 px; no text or official marks. | Probe, idle frame, current icon (hashes above) |

### Shipped icon: clean master (#88)

Chris chose `app-icon-88/painted/painted-b-inbox.png` (artifact `exec-b185edc5-2b4a-475a-bed7-255a1b21d4f7`, above) as the app icon. It is shipped through `app-icon-88/build_painted_icon.swift`, which only resamples and composites: it scales the generated tile onto the 824 px macOS tile, replaces the hazy edge band with the tile's own gradient extended from just inside it, clips to the continuous-corner tile, and draws the drop shadow and hairline rim in code. The character artwork is never repainted or regenerated. No further image-generation call was made. The output is `app-icon-88/painted/painted-b-inbox-clean-1024.png`, and `assets/app-icon/AppIcon.iconset` is Lanczos-3 downsampled from it; the 16 and 32 px images get a light unsharp mask. Mona's resemblance to the Octocat has been reviewed and accepted by the owner; the logo-policy and Octodex caveats above still apply to distribution.
