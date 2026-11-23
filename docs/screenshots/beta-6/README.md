# Beta 6 README image provenance

Native offscreen renders (`--render-snapshots`) of the real SwiftUI views, not live desktop
screenshots or mockups. Every name is an invented Demo fixture; nothing came from GitHub. They are
the unframed renderer outputs from the `render-check` artifact of CI run 45197787346 (the Beta 6
build, source revision `49849ff`), copied unchanged.

- Data source: Demo (offline fixtures); no GitHub account or network.
- Source of the files: `gh run download 45197787346 -n render-check`

| Image | Renderer output | SHA-256 |
|---|---|---|
| settings-scope.png | readme-settings-scope.png | `b36007b3ecebc1d968733e94840ff1f7625f072fbb96f7b7ad109568ce553a67` |
| settings-scope-dark.png | readme-settings-scope-dark.png | `b7b8b66560e695817e327fa5a5f63cda4edfae4c8a36f37b30f336442a07389f` |
| scope-browser-browse.png | scope-browser-browse.png | `a86adcd7f7a7aee0613fcacf1300b8f32e1cb5aa8b4f269c2409ec6c3d7e68cf` |
| scope-browser-browse-dark.png | scope-browser-browse-dark.png | `23608e1bb3b706991df1681856930511f46c73b36ae0cdc6babbdf844c975993` |

The hero Inbox images (#152) are from a later render: the `render-check` artifact of CI run
45246754753 (PR #154, source revision `d4828dd`, `gh run download 45246754753 -n render-check`).
They show the Needs you tile and the collapsed Waiting on others group, which the Beta 5 hero
predates. Unlike the four images above they are framed with `scripts/readme-frame.swift`
(`window footer`: rounded corners, hairline and shadow outside the rendered pixels, and the
offscreen-only "Updates not configured" footer row cropped, 130 px) and recompressed losslessly
with `scripts/png-optimize.py`, as the Beta 5 hero was. 856×1106 px, @2x. Demo fixtures only.

| Image | Renderer output | Renderer output SHA-256 |
|---|---|---|
| hero-inbox.png | inbox87-mona-pet-v1-four.png | `8308c3e6314e650f8eb2f51cb6bf9a7dfa27c421de2cab6504171cdf718ba0f1` |
| hero-inbox-dark.png | inbox87-mona-pet-v1-four-dark.png | `4f60e13dd08d07c59b2f4798a672096a0b277a8e44c93267cf39c774f2b8cf80` |

The mascot images and the other Inbox images are unchanged from `../beta-5`. The Settings image shows the
Monitoring scope and Entitlement approvals sections; the scope browser image is the Choose
Repositories to Monitor window. Offscreen windows are never key, so controls that are on draw grey.
