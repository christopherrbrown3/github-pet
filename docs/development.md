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
- Live data comes from ONE `gh api graphql` request returning the viewer's login and two
  searches, `is:pr is:open review-requested:@me` and `is:issue is:open assignee:@me` (the same
  items, order, URLs and dates as `gh search prs/issues`), each capped at 30. One token answers the
  whole request, so the account and the items can't come from different accounts. If one search
  fails, or reports more matches (`issueCount`) than it returned, the snapshot is *partial*. If both
  fail, or the response is unusable, it's an *error*.
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
- Each GitHub CLI poll's response names the signed-in account (`viewer.login`, compared in memory
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
- Event gestures (#29): one batch of new events plays one gesture, led by its most severe event;
  events arriving while it plays merge into it (no restart, no queue, no backlog). An urgent batch
  preempts an attention gesture, which is not replayed. Attention plays the finite "friendly
  double wave" (docs/design/notifications/attention-storyboard.json): frames 00/01/02/01/02/03 over
  1.9 s with an eased ±5° art-layer lean about the ground anchor; urgent keeps its 2.0 s one-shot.
  Without a gesture, idle loops and attention/urgent hold their static pose. Gestures are
  suppressed (never replayed) under Reduce Motion, snooze and quiet hours, and cancelled if one
  of those starts mid-gesture. All timing uses the app clock. While the art leans, the count keeps
  tracking it (exact-angle contour from outline points precomputed at load, plus a resampling
  reserve of 0.5 pt at 2× and 1.5 pt at 1×); DEMO and the panel stay put; the hover summary
  re-aims only when the gesture starts and ends, clearing the swept outline meanwhile.
  render-check drives the live model (one gesture, merge, end, Reduce Motion) and writes
  `gesture-{64,128,256}.png` filmstrips and `near-touch-*.png` contact sheets.

### GitHub service incidents (#11)
- Source: GitHub's public Statuspage API, `https://www.githubstatus.com/api/v2/incidents/unresolved.json`,
  fetched only when the data source is **GitHub CLI** (Fixtures mode uses demo incidents decoded from a
  Statuspage-shaped sample). It needs no sign-in, so it never uses `gh` or any token; authenticated
  GitHub calls stay with `gh`. URLSession is ephemeral with no cookies, credential store or cache;
  only `https://www.githubstatus.com` is allowed, redirects are refused, requests time out after 15 s,
  and bodies over 512 KB are abandoned while streaming. Decoding is strict: an unknown status or impact,
  a non-Statuspage ID or an unreadable date fails the whole fetch rather than shortening the list.
- Confirmed incident: status `investigating`, `identified` or `monitoring`, not resolved and not
  `maintenance` impact. Scheduled maintenance and resolved incidents are never shown as incidents.
- Quality is separate from the inbox's: *Checking GitHub status…* (unknown), *No active GitHub
  incidents* (fresh, verified none), *N active GitHub incidents* (fresh), *GitHub status is stale*
  (no success for 10 minutes) and *GitHub status unavailable: …* (failure). Only the fresh-none state
  says there are no incidents; stale and failed checks keep last-known incidents dimmed.
- Severity: impact `none`/`minor` → actionable (attention), `major`/`critical` → critical (urgent mood
  while the data is fresh or stale, like a critical inbox item).
- Events: deduped by incident ID. The first success, and the first success after an error or stale
  period, record incidents silently; a new ID on a comparable poll animates once. Updates revise rows
  silently. Escalation of a known open incident to a tier it has never reached (minor → major, minor →
  critical, major → critical) is announced once per tier, as urgent; downgrades and returns to a tier
  already reached are silent (#37 parity). Resolved incidents leave
  the list without animation, and a reopened ID is not announced again (even at a higher impact). Gestures follow the same snooze,
  quiet-hours and Reduce Motion rules as inbox events; privacy mode hides incident names.
- GitHub Status is public, so a `gh auth switch` re-baselines only the inbox; switching the data source
  resets both.
- Rows open only `https://www.githubstatus.com/incidents/<id>` (lowercase alphanumeric ID, no query,
  fragment, port or credentials).

### Incident marker (#37)
- Shown behind the mascot art only for a fresh, confirmed unresolved incident (`IncidentMarker.current`);
  loading, stale and failed status never show it. Tiers: `none`/`minor` → minor, `major` → major,
  `critical` → critical.
- Escalation parity: a known open incident rising to a tier it has never reached (minor → major,
  minor → critical, major → critical) emits one urgent event; returning to a tier already reached,
  downgrades, reopens and baseline/reconnect stay silent.
- Each incident event starts a ~6 s burst; otherwise, and always under Reduce Motion, quiet hours or
  snooze, the marker shows its static frame (it stays visible).
- Every layer is clipped to `IncidentMarker.frame(in:)`: the art square below the design keep-out
  (top 64 of 256 units) and below the whole label zone (`MascotLayout.labelRects`, including the
  count's lowest tracking position) less the minimum gap. render-check rasterises every tier
  (static and burst frames) against every pose's labels at 64/128/256 and 1×/2×: no shared pixels.
- Hover: a top line `GitHub incident: <name>` (public name, kept in privacy mode; `Demo` prefix for
  fixtures). The full hover previews one item fewer so its size, and placement, is unchanged; the
  compact hover stays at two lines. Menu-bar and mascot label: `…, N items, 1 active GitHub incident`.
  The badge counts actionable items only.
- The current drawing is a placeholder in design's 256-unit canvas; design's spec
  (docs/design/incidents/incident-marker.json, PR #38) replaces it.
- Demo incident rows are shown but disabled ("No status page"); they open nothing.

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

### Windows and pointer
- Inbox and Settings windows always open at least as large as their content, even if an older,
  smaller frame was autosaved.
- Panel geometry follows the near-touch badge spacing (#28, docs/design/notifications/
  compact-badge-spacing.md at ef98a48; `MascotLayout`): art S×S centred at the bottom of a panel
  W = max(S, 96, labels) wide. DEMO is fixed at the leading inset; the count is left-aligned in a
  slot reserved for "99+" and, for each drawn pose, moves down so its rounded capsule sits
  1 pt (+0.75 pt raster reserve) from the art's actual top contour (nearest distance), computed
  from per-pose contours precomputed at pack load, in the same render pass as the pose. The art
  top L is the smallest whole point at which DEMO and the widest count clear every pose:
  64/128/256 pt → 96×81, 128×148, 256×270. Labels are never truncated; fills keep at least 4.5:1
  text contrast. Without a pack, the labels stay above the art square. render-check rasterises
  the real view at 1× and 2× for every pose and count text and requires no overlapping pixel and
  a 0.5–2.5 pt nearest gap (measured 0.6–2.0 pt). Resizing (including dragging the size slider)
  keeps the art's ground point fixed on screen; the new origin is saved on the next run-loop
  turn because `$settings` delivers before the new value is stored.
- The hover summary sits beside the character (#27): right by default, left when the right
  screen edge has no room; never above. It is sized to its content first, then anchored to an
  invisible click-through 1×1 window at the arrow tip (the tip can lie just outside the panel).
  Its window never overlaps any visible pixel of any frame of the current state (attention
  uses its upright frames until #29 adds the lean), stays below the tags and on
  screen; within that its height minimises the worst gap to any frame. If a small mascot sits so
  low that a tall summary can't be both on screen and below the tags, staying on screen wins.
  The arrow tip is kept within 12 pt of the static pose. Below 80 pt the hover is a compact
  two-line summary (Demo or count, plus the count's quality; details in the Inbox), and so is
  any size where the full summary can't meet these limits (e.g. 80 pt).
  render-check shows the real windows on screen for 11 cases (64/128/256, left edge, centre,
  right edge; idle, attention, and urgent with privacy off) and requires a worst window-boundary
  gap and an arrow-to-art distance of at most 12 pt, no overlap, tags clear and on screen; it
  also drives a real mascot window through resizes and slider sweeps. Each case writes `hover-<state>-<size>-<position>.png`
  combining art, popover and display edge; the popover is natively captured where the OS
  allows it without Screen Recording permission, otherwise drawn from its window bounds (the
  caption and report say which).
- On the mascot, a press that ends 3 pt or more from where it started is a drag (move and save
  position), even if no intermediate drag events arrived; otherwise it's a click (open Inbox).

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
| Reset baseline | Next snapshot re-seeds silently (inbox and service incidents) |
| GitHub service incident → Inject minor / major | One new incident row; one gesture (major: urgent mood). |
| GitHub service incident → Escalate incidents to major | Escalated incidents announce once, as urgent; repeating does nothing. |
| GitHub service incident → Resolve all incidents | Rows leave quietly; "No active GitHub incidents". |

Mark data stale and Simulate disconnect also apply to service incidents ("GitHub status is stale",
"GitHub status unavailable: simulated disconnect", last-known incidents dimmed); reconnecting replays nothing.

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
| `--render-snapshots <dir>` | Run a fixture scenario (baseline, inject, replay, partial, stale, disconnect, reconnect, privacy), render the real Inbox window, hover summary and mascot offscreen to PNGs in light (`name.png`) and dark (`name-dark.png`) appearance, including loading, urgent and reduced-motion static states (and a missing-`gh` state when `GITHUB_PET_GH_PATH` is set), and write `report.txt` (state, badge, rows, accessibility labels, the mascot's button/press contract, a drag-versus-click probe on the real mascot container, window sizes including Settings). Then quit. Always uses Demo fixtures, default settings and a throwaway preferences suite, whatever other flags or saved settings say, so its output never contains live data and it never changes your preferences. The missing-`gh` step runs only if `GITHUB_PET_GH_PATH` names a path that doesn't exist. No screen-recording permission needed. |
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
