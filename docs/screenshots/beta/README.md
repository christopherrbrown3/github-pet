# Beta README image provenance

Unmodified native offscreen renders (`--render-snapshots`), not live desktop screenshots or
mockups. Every inbox value is an invented Demo fixture; nothing came from GitHub.

- Source revision of the rendered app: `529fdb4591d7db864e3c7ababa830fdfd7cfc332`
- Generated: 2026-11-16T23:15:46Z
- Command: `scripts/readme-screenshots.sh <GitHubPet.app> docs/screenshots/beta <build notes>`
- Renderer invocation: `GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>`,
  with a gh trap (gh was not launched) and throwaway preferences.

## Build

- PR69 head: `529fdb4591d7db864e3c7ababa830fdfd7cfc332` (contains main `0b71732`)
- GitHub Actions run: https://github.com/christopherrbrown3/github-pet/actions/runs/43975833744 (success)
- Artifact: `GitHubPet-app`, ID `14280978361`
- ZIP: `GitHubPet-0.1.0-529fdb4-universal.zip`, SHA-256 `7ee335d0d03f201db2f235f120c9d61f70cff9ff4304f0ff9dda272bb4b4ad72` (matches its `.sha256`)
- App: version 0.1.0, build 213, `GitHubPetSourceRevision` = the head above, universal (x86_64 arm64), `codesign --verify --deep --strict` OK
- Rendered on the developer's Mac (arm64) from the unzipped artifact, never launched normally

## Images

| Image | Renderer output | Pixels | SHA-256 |
|---|---|---|---|
| mascot-idle.png | 01-baseline-mascot.png | 256×300 | `3939f3d279377708fd23fcb1559e65933d7ef1b27d9b32699e0be5fa91530268` |
| mascot-idle-dark.png | 01-baseline-mascot-dark.png | 256×300 | `9cc1618bdc173f90ce4e14faa5ded05adbccb67993eaa33671912aa806ab0e05` |
| mascot-attention.png | 09-attention-static-mascot.png | 256×300 | `2b6ee2da757ab86b68bcfc314d567aac7aba900166fbb2c8ad8476a1fc638b6d` |
| mascot-attention-dark.png | 09-attention-static-mascot-dark.png | 256×300 | `74682512b0a4d46b6295e71791a438e61f2999053e2e4b3a96a2ffec53633351` |
| hover.png | readme-hover.png | 640×230 | `3a750c086f16f50b16ac5f940769e0db119d22bf03335c0078657492f81a022c` |
| hover-dark.png | readme-hover-dark.png | 640×230 | `30065b3d61ebe9cfe17f9e8493ac2f3e01f62495837228a3b23999787e0aa370` |
| inbox.png | readme-inbox.png | 720×724 | `826dfc27459bc86c93473630540c46ff82845aedbbb74e7a4eb8b92a3372bfc5` |
| inbox-dark.png | readme-inbox-dark.png | 720×724 | `34ca57ad9a26842ad9f330166f91670b3291c704fa5bbe199ac0ca6f325a7512` |
| settings-scope.png | readme-settings-scope.png | 1040×1080 | `9099fbb8d2f81c5bc579fb69f811b118cd9049a14ff994808272e832a13f8c8b` |
| settings-scope-dark.png | readme-settings-scope-dark.png | 1040×1080 | `5f724341b6e7e5f9719eee9b34005cdf5808e0a0f40c040d2a4da46e7bb62743` |
| settings-general.png | readme-settings-general.png | 1040×1380 | `771c5a14fd2a27614e02c363010cd7e067acf0664cf6187d6f7e6375ce2de311` |
| settings-general-dark.png | readme-settings-general-dark.png | 1040×1380 | `9501cef3770703764247a416d8b486609452910d476011e1e784ae85bfd9b29c` |

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
