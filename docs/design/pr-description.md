Adds an original image-generated companion pack with idle blinking, a one-shot attention wave and a one-shot concerned gesture. All states use 256×256 RGBA frames, anchor `[128,232]`, explicit timing/loop flags, reduced-motion fallbacks and frame hashes under the developer-agreed v1 manifest.

Includes preserved generation sources/provenance, optional sheets, five geometric menu-bar icon specifications, native inbox/hover/speech-bubble behavior, explicit privacy and unknown-data semantics, and a saved desktop review board/capture. Changes are limited to `assets/mascots/` and `docs/design/`; runtime files are untouched.

Also specifies responsive badges at 64/128/256 points and a clearer 1900 ms finite attention gesture for later Developer handoff. Standalone AppKit size comparisons cover `2`, `2+`, `?`, `99+` and a separate DEMO lane; original wave frames support the proposed two-wave/±5° art-layer sway, with a static reduced-motion fallback. The v1 pack remains unchanged. See `docs/design/notifications/README.md` for native metrics, geometry, event invariants, storyboard and an interactive review preview.

Validation: real-file pack validation passes (dimensions, alpha, paths, hashes, padding, timing, fallbacks and sources/sheets); all exported sequences visually inspected; five SVGs parse; all review links/images resolve; browser desktop capture inspected with thirteen images loaded and no horizontal overflow at 1200 px. See `docs/design/verification.md` and `validation.json` for evidence and limitations.

New design checks: 12 native badge text measurements fit; light/dark native compositions and key poses visually inspected; all 12 source frame hashes remain valid; rotated art bounds remain in canvas; finite timeline/fallback and browser preview completion/Reduce Motion checks pass. These checks do not verify production panel resizing, hover placement, event eligibility, quiet/snooze or native accessibility integration; `docs/design/notifications/validation.md` records limits.

Native app/loader integration, VoiceOver, system accessibility settings and physical-display behavior remain integration QA work. Minor generated contour variation remains. No GitHub endorsement or trademark clearance is claimed. Runtime remains buildable with its independent placeholder. No merge is requested by this action.

Closes #3

Refs #28, #29
