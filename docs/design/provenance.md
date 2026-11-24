# Artwork provenance

## v2 / #138 pilot

Generated with the built-in `image_gen.imagegen` integration, requesting transparent backgrounds. The image integration does not expose its image-model identifier. These are unmodified source images, not packed runtime frames.

| Source | Generation artifact identifier | Prompt intent | References (SHA-256) |
|---|---|---|---|
| `assets/mascots/shared-fx-v1/sources/props-reference.png` | `exec-ec19e4c8-df29-4544-bdf2-1f2e190997f3` | Transparent 2×2 sheet: blank-shield red helmet, unlabelled extinguisher, sealed cream envelope, plain blue-screen phone. | None |
| `assets/mascots/mona-pet-v1/sources/incident-start-a-sheet.png` | `exec-a93e3bc2-5703-4b74-b4b6-314cd938241e` | Identity-preserving 2×2 incident-start poses 00–03: notice, hold helmet, lift helmet, pull helmet on. | `mona-pet-v1/sources/probe.png`: `62eba55c827cfc1fdf355069a2239fc41afec370995b6ec38933cf8fdadb9fe2`; `mona-pet-v1/frames/idle-00.png`: `79bacd0b3040edaa3708f05f322390604dba871e2374b909102f18fd6b9ff7cb`; `shared-fx-v1/sources/props-reference.png`: `3d6c53d34522894af690c5bc83ce0db877fe353e2269c0264b2efe4917365888` |

| `assets/mascots/mona-pet-v1/sources/incident-start-a-sheet.png` (replacement; supersedes pilot above) | `exec-d0959b6e-a36b-43cb-8d2c-266c2f555151` | Retry of incident-start 00–03 with down-left glance, compact held helmet, mid-lift, and low seated helmet. | Same three reference hashes as pilot above. |

Replacement review: 00 glances down-left and 01 holds the helmet compactly; 02 suggests a lift but the brim is close to the head, and 03 still exposes ears and the crown appears high. 00 also has unwanted motion ticks. One hard-failure retry (`exec-32a7effa-9573-40b4-93dd-144a55d7d891`) concealed the ears in 03 but made 02 appear seated; the first replacement was retained as the better sequence. Neither meets all requested constraints; packing, bounds and baseline remain unverified.

| `assets/mascots/mona-pet-v1/sources/incident-start-b-sheet.png` | `exec-d3b86a63-fd27-4947-b76e-ba22890c241d` | Incident-start 04, straight low helmet and tentacles on hips; other cells empty. | Same three reference hashes as pilot above. |

Incident-start B review: ears are concealed and unused cells appear empty; the helmet is broad and the eyebrows are more intense than idle. Crown, baseline and bounds need packing review. No retry.

| `assets/mascots/mona-pet-v1/sources/incident-end-a-sheet.png` | `exec-7b06c54c-fbe2-4c42-9a4c-bd2359cce1cb` | Incident-end 00–03, compact extinguisher poses with low helmet and no spray. | Same three reference hashes as pilot above. |

Incident-end A review: the retry keeps the extinguisher below the face, but ears remain exposed above the brim, nozzle is not held, the poses have little sweep and pose 02 differs in scale. First attempt `exec-9e11a18a-7bc9-4866-a881-ef7656e0dc80` crossed the face with the handle and extended the nozzle; one retry used. Bounds and baseline unverified.

| `assets/mascots/mona-pet-v1/sources/incident-end-b-sheet.png` | `exec-61d7b0fc-79be-4baa-878e-54ce3a726d1a` | Incident-end 04–05, lowered extinguisher then helmet off and brow wipe; other cells empty. | Same three reference hashes as pilot above. |

Incident-end B review: 04 looks down-left and 05 reads as phew; 04 helmet appears large and nozzle extends left; 05 includes motion ticks and the wiping limb touches the face edge. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/new-item-sheet.png` | `exec-30a1a3da-e4ff-45c8-be05-21cecd95f258` | New-item 00–03, perk, crouch and left-side envelope waggle. | Same three reference hashes as pilot above. |

New-item review: 02–03 envelope extends outside normal width; 01 head is lower and scale varies. Retry `exec-7fed3c1a-2cf3-4eb3-8634-7a0035d509cc` moved 03 envelope to the wrong side and still extends the silhouette, so the first sheet was retained. Bounds and baseline unverified.

| `assets/mascots/mona-pet-v1/sources/new-item-b-sheet.png` | `exec-7f924f8a-47be-44c9-aa84-dd4c1cef31a8` | New-item 04, settled with envelope; other cells empty. | Same three reference hashes as pilot above. |

New-item B review: envelope is compact and face clear; unrequested motion ticks appear at right. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/cleared-poke-sheet.png` | `exec-46bc6139-219e-4620-8091-4691f34294ef` | Item-cleared 00–02 and poke 00, curled tentacle gesture and flinching giggle. | Same three reference hashes as pilot above. |

Cleared/poke review: 00 gaze does not clearly read down-left; 03 leans only subtly. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/inbox-zero-sheet.png` | `exec-10339ad3-3316-473a-aca6-aaf36f2e8fa2` | Inbox-zero 00–03, delighted dance and low yay pose. | Same three reference hashes as pilot above. |

Inbox-zero review: 01 and 02 lean opposite ways; 02 eyes remain open and raised limbs may exceed idle width. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/inbox-zero-b-sheet.png` | `exec-987664c0-0c56-46f8-aeaa-e2c0d64f9d5e` | Inbox-zero 04 relaxed with loosely curled tentacles; other cells empty. | Same three reference hashes as pilot above. |

Inbox-zero B review: the relaxed pose closely resembles idle; no visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/drag-drop-sheet.png` | `exec-40afa2b5-2727-41d5-8a13-d865a8f50f75` | Drag 00–01 and drop 00–01, dangling, squash and rebound. | Same three reference hashes as pilot above. |

Drag/drop review: lifted poses retain a raised tentacle rather than all limbs dangling; landing reads squashed. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/dizzy-poke-sheet.png` | `exec-4d3131f5-2591-4c5e-a4de-24aeaf233e49` | Dizzy 00–02 and poke 01, spiral eyes, opposite leans and giggle. | Same three reference hashes as pilot above. |

Dizzy/poke review: 02 is an extra alternate in the third cell; dizzy B remains the planned source for 02–03. Poke tentacle touches mouth as requested. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/dizzy-b-sheet.png` | `exec-676a863f-5abb-4f43-a5da-fdc4985fd2bc` | Dizzy 02–03, right tip and eyes-closed recovery; other cells empty. | Same three reference hashes as pilot above. |

Dizzy B review: the recovery resembles a calm blink rather than an obvious shake. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/ambient-a-sheet.png` | `exec-d967bc34-31f7-4b4d-9629-b0350bbc6d70` | Idle-look 00–02 and idle-stretch 00, glances and beginning yawn. | Same three reference hashes as pilot above. |

Ambient A review: 00 and 01 gaze direction is subtle and 02 tilt is visible but gaze is ambiguous. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/ambient-b-sheet.png` | `exec-29ca414b-d3a9-4f72-a622-d2f03d22e001` | Idle-stretch 01–03 and idle-fidget 00, stretch and curled tentacle. | Same three reference hashes as pilot above. |

Ambient B review: stretched limbs extend well beyond idle width and 02 has open eyes. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/mona-pet-v1/sources/ambient-c-sheet.png` | `exec-33a249fe-8448-478a-adc3-0880a481e125` | Idle-fidget 01–02 and doze 00–01, curled tips and breathing. | Same three reference hashes as pilot above. |

Ambient C review: fidget curl changes are subtle; doze head lowering requires later measurement. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/incident-start-a-sheet.png` | `exec-4943e03f-54d3-4035-82a9-56788edf2a08` | Incident-start 00–03, notice and don helmet. | `little-chris-v1/source/little-chris-poses.png`: `a87cd707e04e8f06ee110dab68d6d176e46ba459163ed317ccab33c32d1128b1`; `little-chris-v1/frames/idle-00.png`: `0272cd3c66e22fc9708696ccfc4fce28f0a1082c992a6b7dd8df2041f80da1f7`; `shared-fx-v1/sources/props-reference.png`: `3d6c53d34522894af690c5bc83ce0db877fe353e2269c0264b2efe4917365888`. |

Little Chris incident-start A review: retry makes 02 visibly in transit but helmet floats above hair and hands do not grip it; crown exceeds idle top. 00 looks down-right instead of down-left. First attempt `exec-d4d7830e-6d82-42c4-98b8-ddfbc2bc1317` seated 02 already. Bounds and baseline unverified; one retry used.

| `assets/mascots/little-chris-v1/sources/incident-start-b-sheet.png` | `exec-2d6faf3b-2828-4df5-8f2e-99e04dabaf04` | Incident-start 04, low helmet and hands on hips; other cells empty. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris incident-start B review: expression has assertive eyebrows; crown and baseline need measurement. No visible effect marks. No retry.

| `assets/mascots/little-chris-v1/sources/incident-end-a-sheet.png` | `exec-d71dd338-0115-4d5a-ae27-2f4df89ba545` | Incident-end 00–03, compact extinguisher and nozzle sweep. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris incident-end A review: 01–03 nozzle extends beyond normal width and helmet crowns appear high; 02 eyes closed. Face is unobstructed and no spray is baked in. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/incident-end-b-sheet.png` | `exec-02a39542-c59c-429f-be75-611577889c5b` | Incident-end 04–05, lowered extinguisher and phew; other cells empty. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris incident-end B review: 04 glances down-left and 05 wipes brow; helmet size and silhouette need measurement. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/new-item-sheet.png` | `exec-07de062b-cfa7-45f2-9e71-29ec148cb247` | New-item 00–03, perk, crouch and envelope waggle. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris new-item review: 02–03 envelope extends outside normal width; 01 crouch and head position differ strongly from idle. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/new-item-b-sheet.png` | `exec-cb5508f0-6c1b-4959-9f23-bff34450e2c7` | New-item 04, settled holding envelope; other cells empty. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris new-item B review: envelope is compact and face clear; no visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/cleared-poke-sheet.png` | `exec-04301d6a-6a5e-450f-90e6-febef200e4df` | Item-cleared 00–02 and poke 00, glance, thumbs-up and giggle. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris cleared/poke review: gestures read clearly; pose scale and baseline need measurement. No visible effect marks. No retry.

| `assets/mascots/little-chris-v1/sources/inbox-zero-sheet.png` | `exec-33063648-24b5-4fa3-94c7-a6b7b8667bbb` | Inbox-zero 00–03, surprise and happy dance. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris inbox-zero review: raised arms extend beyond normal idle width across poses; head tilts noticeably. No visible effect marks. Bounds and baseline unverified. No retry.

| `assets/mascots/little-chris-v1/sources/inbox-zero-b-sheet.png` | `exec-c8d57cea-c20b-4ce3-8b44-7ea34666f24f` | Inbox-zero 04, hands behind head; other cells empty. | Same three Little Chris reference hashes as incident-start A above. |

Little Chris inbox-zero B review: elbows stay close and pose reads content. No visible effect marks. Bounds and baseline unverified. No retry.

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
