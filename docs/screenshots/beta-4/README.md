# Beta 4 README image provenance

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
- Source revision of the rendered app: `210398d857e36813a4e96a538c39ed8fe6e03afd`
- Generated: 2026-11-21T02:11:52Z
- Command: `scripts/readme-screenshots.sh <GitHubPet.app> docs/screenshots/beta-4`
- Renderer invocation: `GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>`,
  with a gh trap (gh was not launched) and throwaway preferences.



## Images

| Image | Renderer output | Frame | Pixels | Renderer output SHA-256 |
|---|---|---|---|---|
| hero-inbox.png | inbox87-mona-pet-v1-four.png | window+footer (cropped 146 px footer (divider at y=940)) | 856×1036 | `64df6b0cbe945160f16ee80eb6d054ef8f6f6df613a0edba769c1df8452676a4` |
| hero-inbox-dark.png | inbox87-mona-pet-v1-four-dark.png | window+footer (cropped 146 px footer (divider at y=940)) | 856×1036 | `7d3da793edbc24c9ee4649369e3356daa9268e158123be4c83d5f2e5532f18e9` |
| inbox-dismissed.png | inbox87-little-chris-v1-dismissed.png | window+footer (cropped 146 px footer (divider at y=678)) | 856×774 | `978f89a16bc5ea6c5f21a1cd89d85ccd361c346b464466ca9cbc693d23e6730b` |
| inbox-dismissed-dark.png | inbox87-little-chris-v1-dismissed-dark.png | window+footer (cropped 146 px footer (divider at y=678)) | 856×774 | `0124ef09d1a378758c60d845358c938f831a3be93b278aede85c06cad6c01b55` |
| inbox-stale.png | inbox87-mona-pet-v1-stale.png | window+footer (cropped 146 px footer (divider at y=988)) | 856×1084 | `edee35d1d4aa7335f59b637b1b298c1a7b61d75cd61347086db84fd30da54581` |
| inbox-stale-dark.png | inbox87-mona-pet-v1-stale-dark.png | window+footer (cropped 146 px footer (divider at y=988)) | 856×1084 | `9de29bbed6dcb6cc66deb62c046db0190b003480aac0b63aa71e730b25fff2b6` |
| mascot-mona.png | readme-mascot-mona-pet-v1.png | plain  | 256×300 | `88dc68ccf27dbfdb89b80c25cd73bef231b9e723bc15bb7ab370cd823e41abf4` |
| mascot-mona-dark.png | readme-mascot-mona-pet-v1-dark.png | plain  | 256×300 | `d04574e24d5df088709b36d944dda890962d81aa37a44d7ece04a68a5f4543f3` |
| mascot-little-chris.png | readme-mascot-little-chris-v1.png | plain  | 256×282 | `34f1b6fad4366417e2db35ec42493cf78edf100ec7a7bbc9b360696d8c7d0a5e` |
| mascot-little-chris-dark.png | readme-mascot-little-chris-v1-dark.png | plain  | 256×282 | `3365b155eff9ff45f1196ca53212aca7c0b3ce305a2f3da7b3e3678a7d2f51d9` |
| settings-mascot.png | readme-settings-mascot.png | window  | 1136×1726 | `3c4bd04a5d15e5d0627d18ef4a64b601ef082220b04aa8ae0e3518c56289656c` |
| settings-mascot-dark.png | readme-settings-mascot-dark.png | window  | 1136×1726 | `54d52d1c5dc4af8bc9df877456ca95a06fc01268c0d33d394bae345544133a83` |
| settings-github.png | readme-settings-github.png | window  | 1136×1486 | `d4a75a459e149c31da4ab5d18a564e5d0834643633601e7298b33794a8db09bc` |
| settings-github-dark.png | readme-settings-github-dark.png | window  | 1136×1486 | `8f15a66d75ab99eeb6400e12ed794a7229ec8eb1d8cd2f29b1ed4317c1f70b5a` |

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
