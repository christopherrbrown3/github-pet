# Beta 7 README image provenance

Native offscreen renders (`--render-snapshots`) of the real SwiftUI views, not live desktop
screenshots or mockups. Every Inbox value is an invented Demo fixture; nothing came from GitHub.
They are the unframed renderer outputs from the `render-check` artifact of CI run 45264615215
(workflow_dispatch on `main` at `01010db`, the Beta 7 source; `main` has since changed only
`updates/appcast.xml`), downloaded with `gh run download 45264615215 -n render-check`.

Each was framed with `scripts/readme-frame.swift window footer` (rounded corners, hairline and
shadow outside the rendered pixels, and the offscreen-only "Updates not configured" footer row
cropped at the last divider, 130 px) and recompressed losslessly with `scripts/png-optimize.py`,
as the Beta 5 and Beta 6 Inbox images were. @2x (144 dpi). Demo fixtures only.

| Image | Renderer output | Frame | Pixels | Renderer output SHA-256 |
|---|---|---|---|---|
| hero-inbox.png | inbox87-mona-pet-v1-four.png | window footer (divider at y=1010) | 856×1106 | `4b611d726d62101933a4ad6b125c9eaae9489c4f8b72022c4a07385d44437aed` |
| hero-inbox-dark.png | inbox87-mona-pet-v1-four-dark.png | window footer (divider at y=1010) | 856×1106 | `48d0a512278cc053235b0efb14eff710f6bbe520715497566a8448a235920e35` |
| inbox-dismissed.png | inbox87-little-chris-v1-dismissed.png | window footer (divider at y=704) | 856×800 | `99ec18863451f4d8a9d9a5de9c5a4b5322773ffe8ba7762496a3b037bedde237` |
| inbox-dismissed-dark.png | inbox87-little-chris-v1-dismissed-dark.png | window footer (divider at y=704) | 856×800 | `a933a22c7778b209bbaa0f982c4308238cfc880edd34d889ccae8cb7fa2a8c09` |
| inbox-stale.png | inbox87-mona-pet-v1-stale.png | window footer (divider at y=1058) | 856×1154 | `18892f5ad3ce435b27a4c0fa37f15187f4d9e27dc433fc5d8c5088a9aee4b857` |
| inbox-stale-dark.png | inbox87-mona-pet-v1-stale-dark.png | window footer (divider at y=1058) | 856×1154 | `190462ae454a39a77d5742fbe4b2806bdb3e8f2978a1c760cce268d9e955fd6d` |

What they show: the Needs you tile ("2 reviews · 1 authored PR · more") with its Needs you list
grouped by Review requests, Your pull requests and Assigned issues, and the collapsed Waiting on
others group (hero); the Dismissed here list under the same tiles (dismissed); and the stale
state, where both tiles and the group headers read "?" or "Count unknown" while the last known
rows stay visible (stale). These replace `../beta-6/hero-inbox*.png`, `../beta-4/inbox-dismissed*.png`
and `../beta-5/inbox-stale*.png`, which predate the Needs you / Waiting on others split.

Not replaced, because they still match the app: the mascot images and `settings-mascot*.png`
(`../beta-5`; the CI settings render is clipped and shows a runner-specific Reduce Motion
caption), and `settings-scope*.png` and `scope-browser-browse*.png` (`../beta-6`; the current
renders are byte-identical to them).
