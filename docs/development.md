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
- Live data comes from `gh search prs --review-requested=@me` and `gh search issues --assignee=@me`.
  If one query fails, the snapshot is *partial*. If both fail, it's an *error*.

### Data quality and events
- States: Loading, Up to date, All clear, Partial data, Stale (no success for 10 min),
  GitHub CLI not found, Not signed in, Error. Only *Up to date* and *All clear* mean the count is
  known. Unknown, partial, stale and failed data is never shown as an empty inbox. The badge is
  hidden when the count is unknown and shows `N+` for partial data.
- Items are keyed by stable IDs such as `reviewRequest:owner/repo#12`.
- The first complete snapshot sets the baseline and fires no events. Unchanged polls never fire
  again. An ID fires at most once, even if it disappears and comes back.
- A snapshot only counts as comparable if the previous one was complete and fresh. Recovering
  from an error, from stale data or from a partial snapshot records IDs silently, so nothing is
  replayed on reconnect.
- Event clips play once (1.6 s), with at most one active and four pending. Critical clips go
  first. They're suppressed under reduced motion, snooze and quiet hours.

### Settings
Settings are stored as one JSON blob in `UserDefaults` (`GitHubPet.settings.v1`). Missing or invalid
fields fall back to defaults, and values outside their range are clamped. They survive relaunch.

- Mascot visibility, size (64–256 pt), and position (saved after each drag; reset in Settings;
  ignored if mostly off-screen).
- **Privacy mode** hides repository names and titles in the inbox, the menu-bar popover, the hover
  summary and accessibility labels, showing generic labels such as "Review request". Counts are
  still shown, and links behave the same.
- **Reduce motion** (also on when macOS Reduce Motion is on) gives a static pose with no clips.
  Colour, symbol and text still change.
- **Snooze** (1 h, 4 h, until 9:00 tomorrow) and **quiet hours** (local time; can wrap past midnight;
  start = end means off) keep the mascot and menu-bar icon calm. The inbox keeps updating, and
  auth/critical states still show as text.
- Data source: Fixtures (default) or GitHub CLI.

### Links
Only `https://github.com/...` URLs are opened, with no userinfo and no port other than 443.
Anything else is blocked and the inbox shows "Link blocked".

## Fixtures and QA hooks

In Fixtures mode the inbox footer has a **Simulator** menu:

| Action | Expected result |
|---|---|
| Inject entitlement event | One new row with a unique ID. Fires exactly one event: attention mood, one hop clip, filled menu-bar icon. |
| Replay current snapshot | No change, no event |
| Next poll: partial | "Partial data", badge `N+`, assigned-issue fixture missing, no events |
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
256×256. The art is continuous-tone, so the whole canvas is scaled smoothly and uniformly into the
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
