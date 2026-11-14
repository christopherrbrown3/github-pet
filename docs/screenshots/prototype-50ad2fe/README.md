# Prototype image provenance

These are unmodified native offscreen UI renders, not live desktop screenshots or design mockups.

- Source commit: `50ad2fe74da7809a4b5f7e91a1b819984270d58e` (open implementation PR18).
- GitHub Actions run: https://github.com/christopherrbrown3/github-pet/actions/runs/43481485342
- Artifact: `render-check`, ID `14065108081`.
- All inbox values are public-safe invented fixtures. The settings panel is a separate scenario.

| Saved image | Original artifact path | Pixels | SHA-256 |
|---|---|---|---|
| mascot.png | 01-baseline-mascot.png | 256×296 | `848c1b66cab1c5234bea4e1f51b5766e51948aadb074e22b086d4d783c0ffd05` |
| inbox.png | 01b-details-inbox.png | 720×554 | `812df412d3855dddd45a94e7902798ed55b153332098faf8a3f93747abf59a5d` |
| settings.png | settings.png | 1040×1352 | `2822c34f7142a51c8fdc1b2ae5240042ff388241022e274799e8bc0d8eb4bdf0` |

The images were visually inspected before inclusion. They do not certify live pointer interaction, actual desktop position, popover-arrow placement, continuous animation, or physical-display behavior. Update this directory/provenance and the README snapshot link when replacing them.
