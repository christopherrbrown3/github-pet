# Beta 5 README image provenance

Native offscreen renders (`--render-snapshots`) of the real SwiftUI views, not live desktop
screenshots or mockups. Every Inbox value is an invented Demo fixture; nothing came from GitHub.
Rendered at @2x (144 dpi). Framing only adds rounded corners, a hairline and a shadow outside the
rendered pixels; `+footer` crops the Inbox below its last divider, removing the update and quit
row (offscreen it reads "Updates not configured" because snapshot mode never starts the updater;
the shipped app shows Check for Updates… there). Kept pixels are unchanged and the PNGs are
recompressed losslessly.

The Settings images are the Mascot and GitHub panes' content: the Mascot | GitHub tab strip
doesn't draw offscreen, so it is left out rather than painted in. Each pane is rendered at a height
that ends between sections (the whole Mascot pane; the GitHub pane through Monitoring scope, as a
window that size shows it before scrolling). Open at login shows what ad-hoc-signed builds read
(unavailable, with the Login Items button). Offscreen windows are never key, so switches that are
on draw grey rather than in the accent colour.

- Data source: Demo (offline fixtures, `--fixtures`); no GitHub account or network.
- Source revision of the rendered app: `b19293bb6a7ff7ac3f5ed4a0409437daffc8a09a`
- Generated: 2026-11-21T19:56:14Z
- Command: `scripts/readme-screenshots.sh <GitHubPet.app> docs/screenshots/beta-5`
- Renderer invocation: `GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>`,
  with a gh trap (gh was not launched) and throwaway preferences.



## Images

| Image | Renderer output | Frame | Pixels | Renderer output SHA-256 |
|---|---|---|---|---|
| hero-inbox.png | inbox87-mona-pet-v1-four.png | window+footer (cropped 146 px footer (divider at y=940)) | 856×1036 | `bffa2081d47cf96339fae976de72aa67e14803fa57eddb1e91cb0ba74f57a512` |
| hero-inbox-dark.png | inbox87-mona-pet-v1-four-dark.png | window+footer (cropped 146 px footer (divider at y=940)) | 856×1036 | `e96b5322ef3dbde76213cd9d1c44980a28df39fc6a7971e1cfe87b620015c3f1` |
| inbox-stale.png | inbox87-mona-pet-v1-stale.png | window+footer (cropped 146 px footer (divider at y=988)) | 856×1084 | `73c2e21a7865636ce7de128508da81fe81ee8f38f2908c1bef40cb6fcc719193` |
| inbox-stale-dark.png | inbox87-mona-pet-v1-stale-dark.png | window+footer (cropped 146 px footer (divider at y=988)) | 856×1084 | `5b469487753cfaa32b73b87b50e37512e71a1715c644688d0203f6933a5ec49d` |
| mascot-mona.png | readme-mascot-mona-pet-v1.png | plain  | 256×300 | `0834c526bb6f4a187b98e65d464a2875b5f7b5ee936e91fad6ecad94e796af34` |
| mascot-mona-dark.png | readme-mascot-mona-pet-v1-dark.png | plain  | 256×300 | `9248d62c2a2d7733cadb7c2608b8e666a49ec95db2743ee3df6423ef8e2237c3` |
| mascot-little-chris.png | readme-mascot-little-chris-v1.png | plain  | 256×284 | `3187e43cd4f73ac075c1fabe6e998456b90733dc788aee4baa6080d54d167f9b` |
| mascot-little-chris-dark.png | readme-mascot-little-chris-v1-dark.png | plain  | 256×284 | `d6eba5abfb569c785d8656df5cb78b6126592880c241092bc91a66e46eee8e1b` |
| settings-mascot.png | readme-settings-mascot.png | window  | 1136×1726 | `a68919fb3203ca3518246442d20ed01cfbdc85316e6fc359cfc6479117829596` |
| settings-mascot-dark.png | readme-settings-mascot-dark.png | window  | 1136×1726 | `19f59b37f7a0e7c2491b6a7342b8482b6f262d9139c330a2dfc39d137a34c59e` |

## Reused from beta-4

These four were re-rendered at this revision and compared pixel for pixel with the beta-4 files.
Nothing in them changed except wall-clock text, or nothing at all, so the beta-4 files are used
as they are and are not copied here (their renderer hashes are in `../beta-4/README.md`).

| Image | Result of the comparison |
|---|---|
| ../beta-4/settings-github.png, settings-github-dark.png | pixel-identical |
| ../beta-4/inbox-dismissed.png, inbox-dismissed-dark.png | only the "Updated" and "Dismissed" clock text differs (about 6,000 px, all in those text lines); the layout and every row are unchanged |

## What changed since beta-4

- hero-inbox: the authored pull request now shows the `arrow.triangle.branch` glyph.
- inbox-stale: the same glyph, and the dimmed last-known rows now keep AA contrast.
- mascot-little-chris: the count badge sits on his head (the panel is 2 px taller).
- mascot-mona: only the count-badge region differs (about 840 px, no visible change in layout).
- settings-mascot: the caption now reads "It shows how many items need you on the desktop pet."

The "Updated"/"Last updated" times in the Inbox images are the render's wall-clock time.

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
