# Native visual retests: contrast and mascot label lane

This record preserves the completed 2026-11-12 visual reviews from the Designer session. It was saved after recovery on 2026-11-13; no images were re-inspected or regenerated during that recovery. The Graphic Designer role used `gpt-6.1-sol` for the reviews. Retesting paused during the intervening Luna model mismatch and resumed only after Sol was restored and verified through Herdr.

The [original review](pr18-6f938c0-render-check.md) at `6f938c0f30375ee0c9684ead61230544fe002f61` identified low-contrast status text (#22) and a DEMO pill covering the lowest tentacle (#23).

## Contrast pass and remaining badge overlap at 088b678

Reviewed local implementation SHA: [`088b67875ef7ed5129f98e60c7f0407f485010d9`](https://github.com/christopherrbrown3/github-pet/commit/088b67875ef7ed5129f98e60c7f0407f485010d9), parent `6f938c0f30375ee0c9684ead61230544fe002f61`. Developer supplied native offscreen captures from the corresponding app in `renders-088b678`. The local commit and parent were independently checked. The Designer did not independently rebuild that app.

Twenty-one representative PNGs were visually inspected:

- Inbox, light and dark: `04-partial`, `05-stale`, `06-disconnected`, `00-loading`, `10-urgent-static`, `11-gh-override` (12 images).
- Mascot, light and dark: `01-baseline`, `10-urgent-static`, `09-attention-static`, `00-loading` (8 images).
- `08-privacy-hover-dark.png` (1 image).

**#22 visual pass:** partial, stale, disconnected and missing-CLI status words use readable semibold primary-label text with separate warning/error symbols in both appearances. Unknown `?`, freshness timestamps and explicit state words remain visible. This is a visual readability result; a numerical native contrast/accessibility certification was not performed on the replacement text.

**#23 remained open at this SHA:** moving DEMO to the top cleared the lowest tentacle but overlapped the upper-left ear. Representative baseline/loading/attention/urgent mascot captures showed the pill around raster `x=8..98, y=8..40` intersecting the ear beginning near `x=57, y=24`. The requested correction was a separate adornment lane outside the artwork rectangle, preserving the pack anchor.

Urgent artwork was distinct and loading displayed an unknown count without claiming all clear. The `09-attention-static` report still said `mood=idle`; explicit attention-fallback coverage was therefore unverified at this SHA. The sampled privacy hover retained generic categories and DEMO labeling.

Original renderer report: [088b678-report.txt](evidence/088b678-report.txt), SHA256 `6671a6ff8bf7bd3603ed5a8d51d34f632cf0164062759d16d45c535b6ebe42e1`.

## Label lane pass at 3cf6fa7

Reviewed implementation SHA: [`3cf6fa7fd95fd6b491802261331ec2bbc8db72aa`](https://github.com/christopherrbrown3/github-pet/commit/3cf6fa7fd95fd6b491802261331ec2bbc8db72aa), parent `088b67875ef7ed5129f98e60c7f0407f485010d9`. Developer supplied native offscreen captures in `renders-3cf6fa7`. This targeted retest was completed under restored `gpt-6.1-sol` in terminal t1f, with launch arguments checked through `hc get graphic-designer` before inspection. Commit/parent were also independently checked.

Exactly eight requested mascot stills were inspected: `01-baseline-mascot.png`, `00-loading-mascot.png`, `09-attention-static-mascot.png`, `10-urgent-static-mascot.png`, plus the corresponding `-dark.png` files.

**#23 visual pass:** DEMO and count tags occupy a separate lane above the artwork. Ears and feet are unobscured in all eight stills, and no artwork clipping was visible. Renderer reports consistently identify a 128×150-point panel: a 128-point artwork square plus a 22-point adornment lane. The art appears contained within that separate area in each inspected state.

The attention report now explicitly selects `mood=attention`, badge `5`; its still displays a raised-limb fallback. Urgent displays a distinct concerned fallback and badge `6`. Loading retains `?`. No material visual delta remained in this targeted sample.

The **prior #22 contrast pass belongs to 088b678** and is inherited unchanged as recorded by PM. This mascot-only retest does not re-certify inbox contrast at 3cf6fa7.

Original renderer report: [3cf6fa7-report.txt](evidence/3cf6fa7-report.txt), SHA256 `5313bf7062640c813ae93f82292e6227165e258f1ee5ddbb26e7d59bf7897f16`.

Developer subsequently reported that 3cf6fa7 became PR18's remote head with successful [CI run 43308089243](https://github.com/christopherrbrown3/github-pet/actions/runs/43308089243). During recovery, `gh run view` independently confirmed that run completed successfully at the exact SHA above. The Designer's visual pass remains based on the supplied local stills; no claim is made that the later CI images were independently compared.

## Review limits

These are native offscreen still-image reviews at the reported 128-point mascot size. They do not establish mouse/hover/menu-bar interaction, animation timing or looping, event deduplication, baseline/reconnect behavior, VoiceOver, focus handling, multi-display movement, persisted position or ground-anchor behavior during dragging, other mascot sizes, or Increase Contrast/Reduce Transparency behavior. Reduced-motion fallback selection is supported by the supplied fixture/report and visible pose; live system-setting behavior was not exercised.

The reports are preserved as small text files. The large PNG sets are not duplicated in this branch. No runtime implementation, board/assignment change, or merge was performed by Designer for these retests. Both results were sent to Developer and PM with their exact reviewed SHAs.
