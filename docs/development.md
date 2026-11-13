# Development

GitHub Pet is a native macOS menu-bar app (SwiftUI + AppKit) built with Swift Package Manager.
It needs no Xcode project, and Xcode itself is optional.

## Requirements

- macOS 13 or later (developed on Apple silicon).
- Swift 5.10 or newer. Either Xcode 16+ or the Command Line Tools (`xcode-select --install`) will do.
- Optional: [GitHub CLI](https://cli.github.com) (`brew install gh`), signed in with `gh auth login`.
  You only need it for the live data source. Fixtures work offline.

## Build, test, run

```sh
swift build                       # debug build of the library and app
scripts/test.sh                   # swift-testing suite (see note below)
scripts/build-app.sh              # release .app -> .build/app/GitHubPet.app
open .build/app/GitHubPet.app     # launch (menu-bar icon + mascot, no Dock icon)
```

`scripts/test.sh` runs `swift test`. If only the Command Line Tools are installed, SwiftPM can't find
swift-testing on its own, so the script adds the CLT framework search paths and turns off the CLT
copy of the Testing/Foundation cross-import overlay, which is incomplete. If you have Xcode,
a plain `swift test` works too.

`scripts/build-app.sh [debug|release]` puts the bundle together from the SwiftPM binary and an
`Info.plist` with `LSUIElement` set, then ad-hoc signs it (`codesign -s -`). The bundle is for local
use only: it isn't notarized or Developer ID signed.

`swift run GitHubPet` also works for quick iteration.

## Layout

| Path | Contents |
|---|---|
| `Sources/GitHubPetCore` | UI-free logic: inbox engine, event baseline/dedupe, settings, quiet hours/snooze, `gh` client, link safety, mascot pack validation |
| `Sources/GitHubPet` | App: `MenuBarExtra` inbox, Inbox and Settings windows, transparent mascot `NSPanel` |
| `Tests/GitHubPetCoreTests` | swift-testing suites for everything in Core |
| `scripts/` | `test.sh`, `build-app.sh` |

## Behaviour contracts

### GitHub access
- Every GitHub call goes through the user's installed `gh`, launched with `Process` and an
  explicit argv. No shell, no stdin, and a 20-second timeout. GitHub Pet never reads,
  stores or asks for tokens, and has no OAuth or GitHub App flow of its own.
- `gh` is looked up via `GITHUB_PET_GH_PATH` if that's set (it's then the only candidate),
  otherwise `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`, then the absolute `PATH` entries.
- `gh auth status --hostname github.com`: exit 0 means signed in. Exit 1 or 4, or "not logged in"
  on stderr, means **Not signed in to GitHub CLI** (hint: `gh auth login`). No executable means
  **GitHub CLI not found** (hint: `brew install gh`).
- Live data comes from `gh search prs --review-requested=@me` and `gh search issues --assignee=@me`,
  each capped at 30 results. If one query fails, or a query returns a full page of 30 (there may be
  more), the snapshot is *partial*. If both fail, it's an *error*.
- Every `gh` child runs with `GH_HOST=github.com`, so a shell configured for another host can't
  make searches disagree with the github.com auth check. Output is read without blocking, and
  both pipes are closed on EOF, the collector deadline or a timeout, even if a descendant still
  holds them open.
- Custom mascot packs: only regular files are read (opened non-blocking, so a FIFO can't stall
  launch), PNG header dimensions are checked before any decode, and a state with too many frames
  is rejected before any of its files are opened.

### Data quality and events
- States: Loading, Up to date, All clear, Partial data, Stale (no success for 10 min),
  GitHub CLI not found, Not signed in, Error. Only *Up to date* and *All clear* mean the count is
  known. Unknown, partial, stale and failed data is never shown as an empty inbox.
- Badge (mascot and inbox header): `N` only for a fresh, complete count; `N+` for partial data;
  `?` whenever the count is unknown (loading, stale, error, CLI missing, signed out). There's no
  badge only for a verified, fresh, empty inbox. The menu-bar accessibility label states the count
  and its quality, for example "GitHub Pet, Demo data, at least 3 items, some sources unavailable".
- **Demo**: fixture data is always identified as Demo. The menu bar shows `DEMO` next to the icon,
  the inbox header shows a DEMO tag and an explanatory line, every row subtitle starts with
  "Demo", the hover summary starts with "Demo data (fixtures)", the mascot shows a DEMO tag, and
  the accessibility labels say "Demo data". Privacy mode never hides it.
- Switching the data source clears the inbox to Loading. Rows, counts and baseline from the
  previous source are never shown as the new source's data, and a slow fetch from an earlier
  session is discarded.
- Each GitHub CLI poll first identifies the signed-in account (`gh api user`, compared in memory
  only, never shown, logged or stored). If `gh auth switch` changes it, the baseline, unread
  markers and clips are reset, so the new account's existing items are not announced as new.
- Unread markers are pruned only after a complete snapshot. A partial snapshot (a failed source)
  keeps them, since recovery does not re-announce those items.
- Items are keyed by stable IDs such as `reviewRequest:owner/repo#12`.
- The first complete snapshot sets the baseline and fires no events. Unchanged polls never fire
  again. An ID fires at most once, even if it disappears and comes back.
- A snapshot only counts as comparable if the previous one was complete and is still fresh at
  the time of the new poll (checked directly, not via a timer). Recovering from an error, from
  stale data or from a partial snapshot records IDs silently, so nothing is replayed on reconnect.
  New IDs are decided before the tracker records anything, so eviction can't make existing IDs
  look new.
- Event clips play once (2.0 s), with at most one active and four pending. Critical clips go
  first. Each clip plays its state's one-shot sequence from its own start, so a second event
  replays it even if the mascot is already in attention. Without a clip, idle loops, and attention
  and urgent hold their static pose. Clips are suppressed under reduced motion, snooze and quiet
  hours. All timing uses the app clock, so the QA clock hooks apply.

### Settings
Settings are stored as one JSON blob in `UserDefaults` (`GitHubPet.settings.v1`). Missing or invalid
fields fall back to defaults, and values outside their range are clamped. They survive relaunch.

- Mascot visibility, size (64–256 pt), and position (saved after each drag; reset in Settings;
  ignored if mostly off-screen).
- **Privacy mode** is **on by default**. It hides repository names and titles in the inbox, the
  menu-bar popover, the hover summary and accessibility labels, showing generic labels such as
  "Review request". Counts and data quality are still shown, and links behave the same. The inbox
  header has a **Show details** link that reveals names and titles in the inbox rows for the
  current app session only (never saved); hover, mascot and menu-bar text stay generic. Turning
  privacy mode on again hides the details immediately.
- **Reduce motion** (also on when macOS Reduce Motion is on) gives a static pose with no clips.
  Colour, symbol and text still change.
- **Snooze** (1 h, 4 h, until 9:00 tomorrow) and **quiet hours** (local time; can wrap past midnight;
  start = end means off) keep the mascot and menu-bar icon calm. The inbox keeps updating, and
  auth/critical states still show as text.
- Data source: Fixtures (default) or GitHub CLI.

### Accessibility
The mascot panel is a single VoiceOver button labelled with the status and the privacy-aware
summary; its press action opens the Inbox, the same as a click.

### Links
Only `https://github.com/...` URLs are opened, with no userinfo and no port other than 443.
Anything else is blocked and the inbox shows "Link blocked".

## Fixtures and QA hooks

In Fixtures mode the inbox footer has a **Simulator** menu:

| Action | Expected result |
|---|---|
| Inject entitlement event | One new row with a unique ID. Fires exactly one event: attention mood, one hop clip, filled menu-bar icon. |
| Inject workflow failure (urgent) | One new critical row with a unique ID. Mood becomes urgent, with a red count badge and the concerned pose. |
| Replay current snapshot | No change, no event |
| Partial data (toggle) | While it's on, every poll is partial: "Partial data", badge `N+`, assigned-issue fixture missing, no events. It stays on across the 30-second fixture poll until you turn it off. |
| Mark data stale | "Stale · last updated …", rows dimmed |
| Simulate disconnect / Reconnect | "Error: simulated disconnect" with rows dimmed. Reconnecting replays nothing, even an entitlement injected while disconnected. |
| Reset baseline | Next snapshot re-seeds silently |

Launch arguments and environment variables:

| Hook | Effect |
|---|---|
| `--defaults-suite <name>` / `GITHUB_PET_DEFAULTS_SUITE` | Store settings in an isolated defaults domain |
| `--reset-settings` | Start from defaults |
| `--fixtures` / `--gh` | Force the data source for this launch |
| `--inject-event-after <seconds>` | Inject one fixture entitlement event after a delay |
| `--start-time <ISO8601>` / `GITHUB_PET_START_TIME` | App clock starts at this instant and runs in real time (snooze, quiet hours, staleness) |
| `--clock-offset <seconds>` / `GITHUB_PET_CLOCK_OFFSET` | Shift the app clock |
| `TZ=<zone>` | Time zone for quiet hours |
| `GITHUB_PET_GH_PATH=<path>` | Use this `gh` (point at a missing path or a fake script) |
| `--render-snapshots <dir>` | Run a fixture scenario (baseline, inject, replay, partial, stale, disconnect, reconnect, privacy), render the real Inbox window, hover summary and mascot offscreen to PNGs in light (`name.png`) and dark (`name-dark.png`) appearance, including loading, urgent and reduced-motion static states (and a missing-`gh` state when `GITHUB_PET_GH_PATH` is set), and write `report.txt` (state, badge, rows, accessibility labels, the mascot's button/press contract, window sizes). Then quit. Always uses Demo fixtures, default settings and a throwaway preferences suite, whatever other flags or saved settings say, so its output never contains live data and it never changes your preferences. The missing-`gh` step runs only if `GITHUB_PET_GH_PATH` names a path that doesn't exist. No screen-recording permission needed. |
| `GITHUB_PET_PACK_DIR=<dir>` | Load this mascot pack instead of the bundled one. If validation fails, the placeholder is used and Settings explains why. |
| `--placeholder` | Draw the native vector placeholder instead of the bundled pack |

Example:

```sh
open -n .build/app/GitHubPet.app --args --defaults-suite qa.run1 --reset-settings --fixtures \
  --start-time 2026-11-12T21:59:30-08:00
GITHUB_PET_GH_PATH=/nonexistent .build/app/GitHubPet.app/Contents/MacOS/GitHubPet --gh --defaults-suite qa.nogh
```

## Mascot pack (schema v1)

Agreed with design: `<pack>/manifest.json` contains `schemaVersion: 1`, `id`, `name`,
`canvas {256, 256}`, `anchor [128, 232]` (bottom-centre ground point) and `states.{idle,attention,urgent}`.
Each state has `frames[]`, `durationMs[]` (125–2000 ms, one per frame, 1–12 frames), `loop` and
`staticFallback`. There's also an optional `frameSha256 {path: hex}`. Paths must be relative `.png`
files inside the pack (no `..`, and no symlinks that escape the pack). Every PNG must be exactly
256×256 and decodable by ImageIO with an alpha channel. The manifest is capped at 256 KB and each
image at 4 MB, and both limits are enforced before decoding or hashing. The mascot panel is the art square plus a fixed 22 pt lane above it for the DEMO and count tags, so adornments never cover the artwork and the panel doesn't change size between states. The art is continuous-tone, so the whole canvas is scaled smoothly and uniformly into the
square mascot panel, which keeps the anchor fixed. Reduced motion uses `staticFallback`.

The default pack is the designer's `assets/mascots/mona-pet-v1` (see `docs/design/`).
`scripts/build-app.sh` copies only its `manifest.json` and `frames/` into
`GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1`. Under `swift run`, the app finds the
repository copy above `.build`. At launch the pack is validated (including SHA-256), and one line
goes to stderr: `GitHubPet: mascot pack mona-pet-v1 loaded from …`, or
`mascot placeholder (…reason…)`. If the pack is missing or invalid, the app still launches with
the placeholder.

## Known limitations (M1)
- The app is ad-hoc signed only, so it isn't notarized. Gatekeeper may need a right-click → Open
  when it's copied to another Mac.
- The live `gh` source covers review requests and assigned issues. Entitlement data and
  configurable entitlement repositories exist only in fixtures for now.
- The event baseline lives in memory. A relaunch re-baselines silently, which is safe but means
  events that arrive while the app is closed are never announced.
- There's no UI test automation yet. GUI behaviour is verified by hand using the hooks above.
