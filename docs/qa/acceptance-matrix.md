# Sprint 1 independent acceptance matrix

This matrix covers the macOS native prototype at the exact developer PR head SHA routed by the PM. It defines acceptance evidence; it does not claim that the prototype has been built or visually checked. Run the UI cases against the executable app, not screenshots or static source inspection.

## Run setup and evidence rules

Use a clean checkout of the routed SHA in the QA worktree. Keep preferences isolated with a unique `--defaults-suite` or `GITHUB_PET_DEFAULTS_SUITE` value for each run. Use fixture mode for behavior checks; use a fake `gh` executable or `GITHUB_PET_GH_PATH` override only for the CLI error cases. Do not sign in to a real account or include personal repository data in fixtures.

Expected build sequence:

```sh
swift build
scripts/test.sh
scripts/build-app.sh
open .build/app/GitHubPet.app
```

Launch the app with `--fixtures` (the default) and an isolated defaults suite for manual cases. The app exposes simulator actions for injecting an entitlement event, replaying the current snapshot, disconnecting/reconnecting, resetting the baseline, producing a partial next poll, and marking data stale. `--inject-event-after <seconds>` is available for timed launch checks. For deterministic time cases, use `--start-time <ISO8601>` or `GITHUB_PET_START_TIME`, optionally `--clock-offset <seconds>` or `GITHUB_PET_CLOCK_OFFSET`, and set the process `TZ` to the zone under test. The app clock then advances in real time. To check an expiry without waiting its full duration, relaunch with the same defaults suite and a start time after the saved expiry.

Record each case as **PASS**, **FAIL**, or **BLOCKED**. “Not run” is the initial state and is not a pass. Every result must identify the exact app SHA, macOS version, fixture or `gh` setup, defaults suite, steps, and observed result. Keep command output with exit codes for builds/tests; use a screen recording for motion and screenshots for visible state/layout. A screenshot used as evidence must come from the running app. Keep evidence outside the repository or attach sanitized artifacts to the PR; never include credentials, tokens, private account data, or internal organization details.

- **PASS:** all listed observations match the pass criteria, with the evidence required by that case.
- **FAIL:** the app runs the case, and a recorded observation contradicts a pass criterion. Include reproduction steps, expected vs. observed behavior, app SHA, and relevant log or capture.
- **BLOCKED:** the case cannot reach its precondition because the build, fixture, permission, or required environment is unavailable or the expected behavior is unspecified. Record the exact blocker and the command/UI evidence. Do not call an unexercised case a pass.

UI, animation, privacy, and positioning cases require direct observation of the running app. A successful build or unit test does not substitute for those checks.

## Build and startup

| ID | Exercise | PASS evidence | FAIL evidence | BLOCKED evidence |
|---|---|---|---|---|
| BUILD-01 | Run the four build commands above at the routed SHA. | `swift build`, `scripts/test.sh`, and `scripts/build-app.sh` each exit 0; the app bundle exists and launches. Save command transcript and exit codes. | A command exits nonzero, the bundle is missing, or launch fails. Save the failing output and SHA. | Swift toolchain or required system framework is unavailable; record versions and the exact error. This machine currently has Swift 6.2.3 and Command Line Tools but no full Xcode; `scripts/test.sh` is expected to support that setup. |
| START-01 | Launch fresh fixture preferences, then quit and relaunch the app. | App stays running as a menu-bar app, exposes its menu-bar control, and presents the mascot according to the default visibility setting. No crash, duplicate menu-bar item, or unexpected Dock app entry. Capture startup and relaunch. | Crash, missing control, duplicate entry, or presentation inconsistent with the fresh defaults. Capture screen and relevant crash/log output. | Bundle cannot be launched or the isolated preferences suite cannot be selected; record the command and error. |

## Menu bar, inbox, mascot, and pointer behavior

| ID | Exercise | PASS evidence | FAIL evidence | BLOCKED evidence |
|---|---|---|---|---|
| UI-01 | Open the menu-bar popover and the Inbox window using the supplied fixture snapshot; open Inbox repeatedly. | Both entry points show the same current inbox items and counts; repeated opens do not create duplicate or stale Inbox windows. Record the fixture and capture both surfaces. | Items/counts differ unexpectedly, a window is duplicated, or an action fails. Capture the surfaces and steps. | Inbox or popover cannot be opened in the routed build; record what is present. |
| UI-02 | Click the mascot and then return to the menu-bar control. | Mascot opens the same Inbox content; the menu-bar interface remains usable. Capture both entry points. | Click does nothing, opens a different/stale list, or disables the menu-bar control. Capture the result. | Mascot visibility cannot be enabled or the click target is inaccessible; record settings and steps. |
| PTR-01 | Place contrasting desktop content behind the mascot. Drag from the visible mascot to a known point, then try dragging from transparent canvas pixels. | The area outside the painted mascot remains transparent; dragging the painted mascot moves the panel; a transparent pixel does not begin a drag. Record before/after captures and pointer actions. | Opaque rectangular fill, incorrect hit-testing, jumpy movement, or unintended drag from transparent pixels. Capture the pointer sequence. | The environment cannot show contrasting content behind the panel or the app exposes no draggable mascot; record the limitation. |
| PTR-02 | Move the mascot, quit/relaunch with the same defaults suite, then use Reset Position. | Position is retained after relaunch; Reset Position returns it to the documented default and leaves the panel onscreen. Record coordinates/captures before, after relaunch, and after reset. | Position is lost, reset is ineffective, or the panel can be stranded offscreen in the tested display setup. Capture the sequence. | No stable display geometry or no reset control is available; record display setup and missing control. |
| HOVER-01 | Hover over the mascot, move away, and repeat with privacy mode on. | A summary appears on hover and clears on exit; hover does not open Inbox, change position, or flicker. With privacy on, the summary is redacted as in PRIV-01. Capture a short recording. | Summary is missing/stale, remains after exit, leaks hidden fields, causes unintended click/drag, or flickers. Include recording. | Hover surface or summary is absent in the routed build; capture the available UI. |

## Events, polling, baseline, and source quality

| ID | Exercise | PASS evidence | FAIL evidence | BLOCKED evidence |
|---|---|---|---|---|
| EVT-01 | With reduced motion, snooze, and quiet hours off, use Simulator → Inject entitlement event. Observe through the full clip and five idle seconds. | Exactly one new event is recorded; the mascot shows at least two distinct frames, plays once, then settles to its idle/context pose within the declared clip duration (reference target 0.8–2.0 s). A five-second recording shows no replay. | No visible motion when enabled, repeated clip, multiple events for one ID, or failure to settle. Include recording and event count. | Event injection or an observable animation surface is missing; record menu contents and settings. |
| BASE-01 | Start a fresh defaults suite, establish the fixture snapshot as the first-sync baseline, and inspect the mascot/inbox. | Existing snapshot items appear without event animation or a new-event attention state. Capture baseline setup and first sync. | Any pre-existing item is treated as a new event. Include the event ID/fixture and recording. | The app cannot reset or establish the fixture baseline; record the available hook and result. |
| DEDUPE-01 | Simulator → Replay current snapshot, without changing fixture data. | No new event, animation, or duplicate inbox item appears. Record before/after event count and replay action. | Replay creates a new event, repeats a clip, or duplicates an item. Record IDs and capture. | Replay action is unavailable or snapshot identity cannot be held constant; record the fixture limitation. |
| DEDUPE-02 | Inject an event while disconnected, then reconnect to the same/returned snapshot. | Reconnect records IDs silently: no replay animation or new attention event, including for the event injected while offline. Record simulator actions and event count. | Reconnect replays a cached/stale event or treats an uncomparable snapshot as new. Capture and identify fixture IDs. | Disconnect/reconnect hooks cannot be run or the event cannot be injected while disconnected; save the available menu/hooks. |
| DATA-01 | Trigger Simulator → Next poll: partial. | Header says “Partial data”; affected counts use `N+` where incomplete; prior items remain available; no new event fires from the partial snapshot. Capture header, count, items, and event count. | Partial data is presented as a complete count/zero, valid prior items disappear, or a new event fires. Capture before/after. | Partial hook is missing or cannot be triggered; record exact menu and output. |
| DATA-02 | Trigger Simulator → Simulate disconnect after loading items. | UI says “Error: simulated disconnect”; last items remain but are greyed; mascot stays idle rather than showing zero/empty or attention. Record before/after and event count. | Items are erased, shown as fresh/empty, or a new event/attention state appears. Capture before/after. | Disconnect hook or prior fixture items are unavailable; record the setup. |
| DATA-03 | Trigger Simulator → Mark data stale. | UI says “Stale · last updated <time>”; last successful items and timestamp remain; stale data is not presented as fresh/empty and creates no new event. Capture the source state and timestamp. | Timestamp is reset, data is presented as fresh/zero, or stale→fresh creates a new event without a comparable snapshot. Capture the transition. | Stale action or timestamp is not observable; record the available controls/output. |

## Links, CLI availability, and privacy

| ID | Exercise | PASS evidence | FAIL evidence | BLOCKED evidence |
|---|---|---|---|---|
| LINK-01 | Use a fixture row with a canonical `https://github.com/...` link, then fixtures with `http`, a lookalike host, userinfo, a nonstandard port, `file:`, and `javascript:` URLs. Repeat while privacy mode is on. | Only HTTPS URLs whose host is exactly `github.com`, with no userinfo or unusual port, are opened by `NSWorkspace`; rejected links show “Link blocked.” Privacy changes visible labels but not valid link behavior. Record the attempted URLs, opener/browser result, and blocked-link message. | Any rejected URL opens, a valid URL is rewritten to another destination, privacy blocks a valid link, or no visible rejection is shown. Capture and log the attempted fixture. | Invalid-link fixtures or an observable system opener result are unavailable; record the missing hook. Never click an untrusted URL that was not first confirmed blocked in an isolated fixture. |
| GH-01 | Select the `gh` source and set `GITHUB_PET_GH_PATH=/nonexistent`. | App shows “GitHub CLI not found” with the `brew install gh` hint; mascot indicates urgent status; app remains usable and does not expose or request a token. Save sanitized UI/log evidence and environment override. | Crash, silent empty state, missing hint, or credential read/request. Capture UI/logs; do not include environment secrets. | Source cannot be switched to `gh` or override is ignored; record the app setting and launch environment. |
| GH-02 | Point `GITHUB_PET_GH_PATH` at a temporary fake executable; run once with exit 1 and once with exit 4 for `auth status`. | Both cases show “Not signed in to GitHub CLI” with “Run: gh auth login”; mascot indicates urgent status; no token is read and the app remains usable. Save fake executable behavior, sanitized invocation/output, and UI capture for each exit code. | Either exit code produces the wrong state, a crash, retry storm, or evidence the app reads/presents a token. Capture UI/process/log evidence without secrets. | Fake executable cannot be invoked or the CLI source is unavailable; record exact arguments/result. Do not use a real authenticated account. |
| PRIV-01 | Enable privacy mode and load synthetic repo/title strings. Inspect menu-bar popover, Inbox window, hover summary, mascot accessibility label, and event surface; relaunch; then disable privacy. | All specified surfaces replace repository/title with the generic kind label while counts remain visible; setting persists on relaunch; disabling restores fixture labels. Privacy does not change valid link opening. Capture each surface and accessibility label with synthetic values only. | Any surface leaks repo/title in text, accessibility metadata, or event presentation; counts disappear; or setting does not persist. Capture the specific surface. | A named surface or accessibility inspector is unavailable; record the missing surface/tool. |

## Motion, snooze, and quiet hours

| ID | Exercise | PASS evidence | FAIL evidence | BLOCKED evidence |
|---|---|---|---|---|
| MOT-01 | Observe ambient/event animation with reduced motion off. Enable the app setting, relaunch, then trigger another event. Repeat with macOS Reduce Motion enabled. | App setting persists; either source of Reduce Motion yields a static mascot pose with no breathing/blink/bounce/event clip; state labels/colors and inbox updates still change. Record settings and motion/no-motion screen recordings. | Motion continues when reduced, status meaning disappears, or setting fails to persist. Include recordings and setting state. | System Reduce Motion cannot be toggled in the test environment; mark that subcheck BLOCKED with macOS version and still complete the app-setting subcheck. |
| SNOOZE-01 | In fixture mode, separately select 1h, 4h, until tomorrow 9:00, and Off. During each active snooze inject an event; then relaunch with the same defaults suite and `--start-time` just after the saved expiry. | While snoozed, inbox and counts update; mascot does not switch to attention or play event clips; menu-bar icon stays non-alert. Selection persists across relaunch; after expiry normal attention returns; Off restores attention immediately. Capture start times and event result at active and expired times. | Event is hidden from inbox/counts, mascot/icon alerts during snooze, expiry is early/late relative to the app clock, or setting is lost after relaunch. Record timestamps, `TZ`, and state. | Clock arguments/environment are unavailable in the routed build or saved expiry cannot be observed with the same preferences suite; record the launch command and exact limitation. |
| QUIET-01 | Verify default disabled and 22:00–07:00 settings. With a fixed `TZ`, launch at the quiet-hours start, end, and just outside each boundary using `--start-time`; test a cross-midnight range and equal start/end. | Start/end use the process time zone; during quiet hours the inbox and count badge update while mascot/icon attention and event clips are suppressed; critical/auth text remains visible. Cross-midnight ranges work; equal start/end disables quiet hours; setting persists after relaunch. Record ISO start time, `TZ`, settings, and event observation for each boundary. | Alert behavior violates those rules, schedule uses the wrong time zone/boundary, cross-midnight fails, or equal endpoints are treated as a full-day window. Capture settings and event behavior. | Clock arguments/environment or process `TZ` are unavailable in the routed build; record the launch command and exact limitation. |

## Data and event expectations

Source loading must preserve last-known content while refreshing. Partial data must be visibly incomplete and must not turn unknown counts into zero. Errors retain prior content as stale/unavailable rather than clearing it. Freshness is measured from the last successful observation; stale state must preserve its last-success time. Event IDs observed in a non-comparable snapshot are recorded silently so they cannot replay after reconnection; unchanged snapshots, first sync, and stale/error-to-fresh transitions without a comparable prior snapshot do not create new events. A verified new event can create one clip, then the mascot settles. These rules apply independently of any local GitHub CLI authentication mechanism; this QA plan does not exercise or port OAuth/App authentication.

## Run record

Copy this block into the PR review when executing the matrix. Attach sanitized evidence using the case IDs above.

```text
App head SHA:
macOS version / architecture:
Swift version:
Build and test commands / exit codes:
Fixture mode and defaults suite:
System Reduce Motion state:
Local time zone / time (for QUIET-01):
App clock start / offset (if used):
Case results (PASS / FAIL / BLOCKED + evidence reference):
Known blockers:
```
