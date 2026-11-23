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

The Mascot, Inbox and mascot images are unchanged from `../beta-5`. The Settings image shows the
Monitoring scope and Entitlement approvals sections; the scope browser image is the Choose
Repositories to Monitor window. Offscreen windows are never key, so controls that are on draw grey.
