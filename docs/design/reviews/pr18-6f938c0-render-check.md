# Native render visual review — PR18

CI run 43305571298, artifact render-check (13982833127), exact SHA 6f938c0f30375ee0c9684ead61230544fe002f61. Run metadata and artifact head SHA independently matched through gh. Download: /tmp/github-pet-native-review-43305571298.

Inspected all 24 PNGs: inbox, hover and mascot for 01-baseline, 02-injected, 03-replayed, 04-partial, 05-stale, 06-disconnected, 07-reconnected and 08-privacy; also read report.txt. Stills only.

P2 — Quality text contrast. 04-partial-inbox.png (Partial data), 05-stale-inbox.png (Stale), and 06-disconnected-inbox.png (Error: simulated disconnect): small colored status text is difficult to read on the #ececec background. Strongest sampled colored glyph pixels give approximately 1.86:1, 1.84:1, and 2.97:1 respectively. Samples are from the rendered PNGs, not assumed CSS values or a native accessibility audit. Use standard primary label text plus warning/error symbol, or a darker appearance-aware semantic foreground reaching the 4.5:1 normal-text design target. Preserve explicit quality words, timestamps and unknown badge.

P2 — Mascot badge occlusion. All eight *-mascot.png stills show the bottom DEMO pill overlapping the lower central tentacle/ground region. Example 01-baseline-mascot.png, 256x256 raster for 128x128 points: pill occupies approximately y216..248 while artwork ground baseline is y232. Keep DEMO visible but place it in a separate adornment lane outside the art bounds (or reserve space without moving/changing the pack anchor). Ears and upper limbs otherwise appear contained; this is overlay occlusion, not evidence of source image cropping.

Positive evidence: inbox rows and controls fit the shown 360-point width; title rows remain legible; all inbox/hover/mascot images carry DEMO/fixture labeling; privacy inbox/hover replace titles and repository strings with generic categories; partial shows 3+ plus Partial data; stale/error show ? plus explicit state and last-known labeling, rather than zero/all clear. No private metadata leak was visible in the supplied privacy stills.

Limits: only light-appearance native captures; no actual menu-bar image, mouse/hover interaction, focus, VoiceOver, link opening, animation timing, deduplication behavior, baseline/reconnect event behavior, dark/high-contrast appearance or multi-display checks established. Report identifies idle/attention moods, but the stills do not establish all clip frames or urgent-state artwork selection. Request a direct static urgent/attention render fixture for full per-state art acceptance. Unknown initial/loading states are absent; only stale/error unknown-count presentation was inspected.

No repository/runtime changes, issue assignment, board changes or merges performed.

## Durable source references

- Reviewed implementation commit: [`6f938c0f30375ee0c9684ead61230544fe002f61`](https://github.com/christopherrbrown3/github-pet/commit/6f938c0f30375ee0c9684ead61230544fe002f61), PR #18.
- [CI run 43305571298](https://github.com/christopherrbrown3/github-pet/actions/runs/43305571298).
- Artifact: `render-check`, id `13982833127`, archive digest `sha256:4b7321285c6011a8e8b8ba78200dfe08ae11a19861a0e3c4c17cf3f0f523e084` as reported by GitHub artifact metadata. This digest was not independently recomputed from the ZIP.
- Reproduce download through authenticated GitHub CLI: `gh run download 43305571298 --repo christopherrbrown3/github-pet --name render-check --dir <new-evidence-directory>`.
- GitHub reported artifact expiry 2027-02-10. The 24 PNG files are not duplicated in the repository; this written review preserves the findings and measurement limits.

PM accepted these findings and authorized Developer to fix runtime contrast and DEMO badge placement. This document does not verify those later changes. Await updated exact-SHA light/dark and urgent/loading captures for follow-up inspection.
