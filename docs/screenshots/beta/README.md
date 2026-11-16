# Beta README image provenance

Unmodified native offscreen renders (`--render-snapshots`), not live desktop screenshots or
mockups. Every inbox value is an invented Demo fixture; nothing came from GitHub.

- Source revision of the rendered app: `49cdc0cf7d48c94b35d95a6ad579f2981f69ac26`
- Generated: 2026-11-16T20:01:11Z
- Command: `scripts/readme-screenshots.sh <GitHubPet.app> docs/screenshots/beta <build notes>`
- Renderer invocation: `GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>`,
  with a gh trap (gh was not launched) and throwaway preferences.

## Build

- PR69 head: `49cdc0cf7d48c94b35d95a6ad579f2981f69ac26` (main `0b71732` merged)
- GitHub Actions run: https://github.com/christopherrbrown3/github-pet/actions/runs/43942417090 (success)
- Artifact: `GitHubPet-app`, ID `14263502850`
- ZIP: `GitHubPet-0.1.0-49cdc0c-universal.zip`, SHA-256 `ef7b13af8c54e7b194b892ab2dd2f3d3baabc25607eba3881758034c60c0a7da` (matches its `.sha256`)
- App: version 0.1.0, build 208, `GitHubPetSourceRevision` = the head above, universal (x86_64 arm64), `codesign --verify --deep --strict` OK
- Rendered on the developer's Mac (arm64) from the unzipped artifact, never launched normally

## Images

| Image | Renderer output | Pixels | SHA-256 |
|---|---|---|---|
| mascot-idle.png | 01-baseline-mascot.png | 256×300 | `3939f3d279377708fd23fcb1559e65933d7ef1b27d9b32699e0be5fa91530268` |
| mascot-idle-dark.png | 01-baseline-mascot-dark.png | 256×300 | `9cc1618bdc173f90ce4e14faa5ded05adbccb67993eaa33671912aa806ab0e05` |
| mascot-attention.png | 09-attention-static-mascot.png | 256×300 | `2b6ee2da757ab86b68bcfc314d567aac7aba900166fbb2c8ad8476a1fc638b6d` |
| mascot-attention-dark.png | 09-attention-static-mascot-dark.png | 256×300 | `74682512b0a4d46b6295e71791a438e61f2999053e2e4b3a96a2ffec53633351` |
| mascot-urgent.png | 10-urgent-static-mascot.png | 256×300 | `f7de867955c31e1f0d3562c0b801c625801011b5910834fae5b10ec5ab5a12ab` |
| mascot-urgent-dark.png | 10-urgent-static-mascot-dark.png | 256×300 | `6691fb80a877e8572edc910244c447275f0b67d4b443cbf2438cbd284d737388` |
| hover.png | 02-injected-hover.png | 640×230 | `c147defbd38de3e026253a60fce21f9cd5678f8b5876b2ab60baa1363ce1846d` |
| hover-dark.png | 02-injected-hover-dark.png | 640×230 | `7262e8d24cffed6476eef1adb942b3e02f09e9a540790ee047697f4ebf42ac2a` |
| inbox.png | 01b-details-inbox.png | 720×724 | `c70e18498ef9fcbfdeb9a17f719882a9c194964c35948e2a4cb9860ffe3434a1` |
| inbox-dark.png | 01b-details-inbox-dark.png | 720×724 | `e78e1193fd944ba72f43c2a05bcd076093b025dfee3ff2e4427c60d726fde577` |
| settings.png | settings-full.png | 1040×2800 | `1c8850fd627d69f2f3c4c55c41ec5e33802b5f01cdb3acc296e890f83878b59a` |
| settings-dark.png | settings-full-dark.png | 1040×2800 | `e7c49122e550488c939744f5636b2219dbf50d0b9514509f88156fda446e17e2` |

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
