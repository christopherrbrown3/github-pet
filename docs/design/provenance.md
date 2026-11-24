# Artwork provenance

## v2 / #138 pilot

Generated with the built-in `image_gen.imagegen` integration, requesting transparent backgrounds. The image integration does not expose its image-model identifier. These are unmodified source images, not packed runtime frames.

| Source | Generation artifact identifier | Prompt intent | References (SHA-256) |
|---|---|---|---|
| `assets/mascots/shared-fx-v1/sources/props-reference.png` | `exec-ec19e4c8-df29-4544-bdf2-1f2e190997f3` | Transparent 2×2 sheet: blank-shield red helmet, unlabelled extinguisher, sealed cream envelope, plain blue-screen phone. | None |
| `assets/mascots/mona-pet-v1/sources/incident-start-a-sheet.png` | `exec-a93e3bc2-5703-4b74-b4b6-314cd938241e` | Identity-preserving 2×2 incident-start poses 00–03: notice, hold helmet, lift helmet, pull helmet on. | `mona-pet-v1/sources/probe.png`: `62eba55c827cfc1fdf355069a2239fc41afec370995b6ec38933cf8fdadb9fe2`; `mona-pet-v1/frames/idle-00.png`: `79bacd0b3040edaa3708f05f322390604dba871e2374b909102f18fd6b9ff7cb`; `shared-fx-v1/sources/props-reference.png`: `3d6c53d34522894af690c5bc83ce0db877fe353e2269c0264b2efe4917365888` |

Both images are 1254×1254 and have alpha channels. Visual review: the helmet in pose 02 is already seated rather than clearly in transit, pose 01 looks forward rather than alert down-left, and pose 00's gaze is not clearly down-left. Helmet-on poses change the apparent head silhouette and scale; the helmet crown and overall bounds require measurement during later packing and review. No runtime frame, baseline, or bounds validation is claimed here. The props sheet places the helmet close to the central cell boundary. No retry or retouch was performed.

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
