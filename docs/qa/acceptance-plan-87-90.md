# Functional acceptance plan: #87 Settings panes, #87 Inbox redesign, #90 update check (phase 1)

Written 2026-11-20 from the issue acceptance criteria on main 96b70d0. Plan only: nothing here has been run. It extends `acceptance-matrix.md` (which still defines PASS/FAIL/BLOCKED and the run record) and applies to the exact PR head SHAs the PM routes. Branch names: `feat/87-settings-panes`, `feat/87-inbox-redesign`, `feat/90-update-check`.

## Evidence rules (as in PR75/PR86 reports)

Each report states: exact head SHA and base, exact CI run ID and conclusion for that SHA, macOS/Swift versions, build commands with exit codes, SHA-256 of any built `.app` zip or binary used, the defaults suite, and per case PASS / FAIL / BLOCKED with the method used. Always say which tier produced the evidence (below) and what was **not** verified. A snapshot PNG is not evidence of interaction, motion or keyboard/VoiceOver behavior. Never delete or reset preference plists; list any left behind for Chris. No network, no real account, synthetic data only.

## Verification tiers

| Tier | Tool | Can establish | Cannot establish |
|---|---|---|---|
| S | Source/diff review of the exact SHA (including a whole-`Sources` grep for write verbs, token reads and URL builders) | Invariants by absence (no write calls, no token access, no `/releases/latest`-only logic), wiring, copy | Runtime behavior |
| R | QA scenario runner: `--simulate-monitoring-scope --qa-scenario <name\|path.json> --qa-output <dir>`; per step JSON state plus offscreen PNGs of Inbox, mascot and Settings (Settings only for the `open-settings` step) | Model state after Inbox/Settings actions: status text, badge, rows, attention, dismissal state, settings values, mascot skin/privacy/reduced-motion; deterministic clock via `clock-set` / `clock-advance`; no gh process, no network, no permissions needed | Real window layout/sizing, focus, hover, keyboard navigation, VoiceOver, animation, login item, anything needing the real clock, dock/menu bar. It exposes **no snooze or quiet-hours action today** and renders only the Settings sections it knows (`assignment`, `mascot`, or the whole `SettingsView`). New panes or actions need developer-owned runner support, or they fall to tier A |
| N | `--render-snapshots <dir>` / `scripts/render-check.sh`: fixture scenario, light and dark PNGs, AX tree dump, report text | Dark/light stills, AX labels and values of the real views, privacy redaction in AX text | Interaction, motion, focus order, actual VoiceOver speech |
| A | Launched `.app` from `scripts/build-app.sh` with `--defaults-suite <unique>` and fixture source (`--start-time`, `--clock-offset`, `--inject-event-after`, Simulator menu) | Window behavior, real layout and scrolling, keyboard, hover, pointer, Settings navigation and persistence across relaunch, menu-bar item, login-item registration, real appearance toggle | Anything needing a real GitHub account unless a fake `gh` (`GITHUB_PET_GH_PATH`) is used; a real update install; notarized-app behavior |

Where a case lists tier R or N, a tier A spot check is still required for anything about layout, scrolling, focus or motion before calling the whole criterion PASS.

## Cross-cutting invariants (check on every PR, both slices)

| ID | Invariant | Pass means | Tier |
|---|---|---|---|
| INV-01 | Stale, partial, unknown, loading and error never look like an empty or healthy inbox | For each source state (loading, stale, partial `N+`, error, unknown): header text names the state, last-known rows remain (greyed when stale/error), no "All caught up", no green or "operational" styling, mascot not in the empty/delighted pose, and counts never become 0. Menu-bar item, hover and AX label agree with the Inbox. Check both zero-row and non-empty cases, and the new empty-state mascot pose in every non-healthy state | R + N + A (R: `partial`, `refresh`, `source`; stale and error via Simulator menu in A) |
| INV-02 | Snooze and quiet hours never stop monitoring | While snoozed or inside quiet hours: polls continue (poll count or last-success advances), inbox rows and counts update, stale/error/auth text still shows, privacy unaffected; only attention (alert icon, mascot attention, clips) is suppressed. Expiry and Off restore attention. The Alerts pane states this ("suppress interruptions, not fetching, inbox updates, or state integrity") and any new master notification toggle is distinct from snooze and quiet hours and does not stop fetching | S + A (needs launched app with `--start-time`; see runner gap). R only if the developer adds snooze/quiet actions |
| INV-03 | Privacy mode | With privacy on, repository names and titles are replaced everywhere new: redesigned rows, grouped section headers, tooltips, hover summary, mascot/menu-bar AX labels, Settings previews and dismissed list, the update-check UI (no repo data should appear there anyway). Counts remain; valid links still open. Persists across relaunch | R (`privacy`) + N (AX dump) + A |
| INV-04 | gh-only authentication | No PAT field, OAuth, token read/store, Keychain, `gh auth token`, or `GH_TOKEN` handling added. GitHub pane shows CLI status, readable error and recheck, and uses only `gh`. Source grep for `token`, `Keychain`, `Authorization`, `URLSession` in new code | S, plus A with fake `gh` (GH-01/GH-02 equivalents in the new pane) |
| INV-05 | No GitHub write actions | Whole-`Sources` grep for `POST`, `PUT`, `PATCH`, `DELETE`, `--method`, `-X` (other than GET) and mutation GraphQL finds nothing new. Approve/review/dismiss controls only open a github.com page (LINK-01 rules) or act locally | S |
| INV-06 | Dismissal is local only, with restore | Dismiss hides the row without any network/gh call; View dismissed lists it; Restore returns it; Undo (if offered) restores; persisted per account/scope; a dismissed item that changes is handled per existing dismissal rules; dismissed rows never reduce the "unknown/partial" signaling or the badge incorrectly | R (`dismiss`, `view-dismissed`, `restore-before-display` and related built-ins) + A (hover/keyboard/Undo) |
| INV-07 | Hiding the mascot, snooze, privacy, reduced motion and monitoring stay independent | Toggling each leaves the others and the source state unchanged. Hidden mascot still allows the menu-bar item to show attention state | R + A |
| INV-08 | Existing settings are retained | Every control present on main (scope/targets/apply, assignment filter and its explanatory text, Actions toggles, source, privacy, reduced motion, login item, size, skin, reset position, quiet hours, snooze) is reachable and works in the new panes, including controls that were below the fold. Defaults and persisted values from a main-built defaults suite load unchanged | S + A (compare against main's `SettingsView`) |

## #87 Settings panes (Mascot, Alerts, GitHub)

| ID | Check | Tier / limit |
|---|---|---|
| SET-01 | Three panes exist and are navigable by mouse and keyboard; window sizes sensibly, remembers nothing it should not; opens the last/first pane predictably; no long scroll | A |
| SET-02 | Mascot pane: show/hide, Mona and Little Chris cards using the bundled imagery, alert badge shown in preview, size slider with value, reset position, reduce motion, open at login with the "install in Applications" explanation when registration is unavailable | R (`mascot-skin`, `reduce-motion`, `mascot-position`, settings snapshot); login item and hiding need A |
| SET-03 | Selected skin, size and badge in preview match the desktop pet and Inbox (no redrawn assets, badge not double counted, not detached) | N (stills of both) + A |
| SET-04 | Alerts pane: quiet hours enable/start/end, snooze durations and an explicit current snoozed/not-snoozed state (with expiry), privacy, assignment filter with explanatory text, and the explicit non-monitoring-stopping sentence | A (runner has `assignment` and `privacy` only); S for copy |
| SET-05 | Quiet hours semantics unchanged: boundaries, cross-midnight, equal start/end disables, process time zone (reuse QUIET-01 and SNOOZE-01) | A with `--start-time`, fixed `TZ` |
| SET-06 | GitHub pane: CLI status, understandable error, recheck; monitoring scope and entitlement/Actions configuration; incidents as a separate source; verbose details behind a disclosure | R (`scope`, `account`, `apply`, `source`, settings-cancel scenarios) + A for gh states using `GITHUB_PET_GH_PATH` (missing, exit 1/4, working fake) |
| SET-07 | Scope editing keeps its existing apply/cancel semantics across panes (cancel restores active scope; pending edits not lost or applied silently on pane switch/close) | R (existing settings-cancel scenarios) + A for pane switching |
| SET-08 | Persistence: every setting survives relaunch with the same suite; a suite written by main's build loads without loss (INV-08); `--reset-settings` unaffected | A (list the plists left, never delete) |
| SET-09 | Dark/light, large text, VoiceOver labels, tab order, focus rings, contrast | N (dark/light, AX tree) + A for keyboard; real VoiceOver listening is a separate human check, mark BLOCKED if not done |

## #87 Inbox redesign

| ID | Check | Tier / limit |
|---|---|---|
| INB-01 | About four rows visible without oversized empty space; long lists (50+) scroll and do not collapse the list (#20 regression) | A for real sizing; N stills as supporting evidence |
| INB-02 | Assigned, waiting (authored/waiting), approvals and incident rows are visually and textually distinct, SF Symbols consistent, repository subordinate to title, incident severity coloring reserved for incidents/errors | R (`inject-assigned-issue`, `inject-incident`, `authored`, `visibility`) + N |
| INB-03 | Source-state header and empty state per INV-01; healthy empty shows the mascot pose and "all caught up" only when data is complete, fresh and zero | R + N + A |
| INB-04 | Row actions: open in GitHub (URL validation rules from LINK-01), dismiss, review; hover actions and keyboard access; no write action | S + A |
| INB-05 | Dismiss, View dismissed, Restore, Undo feedback per INV-06; dismissed count display; dismissal not applied to incidents if main excludes them | R + A |
| INB-06 | Mascot, badge and Inbox agree on count and skin; no animation loop in the active inbox; reduced motion yields static informative states | N + A |
| INB-07 | Dark/light, keyboard navigation, VoiceOver labels (row AX label includes kind and, when privacy is on, no repo/title), window reuse (UI-01) | N (AX dump) + A |
| INB-08 | Regression: baseline/no replay, partial, stale, disconnect, dedupe (BASE-01, DEDUPE-01/02, DATA-01/02/03) unchanged by the redesign | A with Simulator menu; R `partial` |

## #90 update check, phase 1

Phase 1 means check + version display + release notes + open the download page. Automatic install is not claimed; Sparkle or in-app install is out of scope until #89 decides. Any wording that says or implies auto-install, one-click install or silent updates is a FAIL.

| ID | Check | Tier / limit |
|---|---|---|
| UPD-01 | Installed version and build shown (matches `VERSION` and `CFBundleVersion`/commit count of the built bundle); "Check for Updates…" reachable from the menu and any GitHub pane entry; last-check time and current status shown | A (built bundle) |
| UPD-02 | States: Checking, Up to date, New version available, Error with Retry; Downloading/Ready to install do not appear in phase 1 | A with a fixture/fake endpoint (needs a developer-provided override or injectable transport; tests must not touch the network, and neither may QA unless the PM approves one real release query, which is read-only and unauthenticated) |
| UPD-03 | **A failed check never reads "Up to date"**: offline, DNS failure, HTTP 403/429 rate limit, 5xx, timeout, malformed JSON, missing fields, bad version string and empty release list all show an error or unknown state with Retry and a stale last-check value, never "up to date"; a prior successful result is not reused as current | A with fault-injected endpoint + S (read the status mapping; every non-success path must not map to up to date) |
| UPD-04 | Channel logic: stable ignores prereleases; beta channel includes them; no automatic switch to beta; does not rely solely on `/releases/latest` (beta builds are prereleases); drafts ignored; version comparison for `1.0.0-beta.3` < `1.0.0-beta.4` < `1.0.0` and build number tie-breaks; a newer release than the one installed offers it, an older/equal one does not (superseded and downgrade cases) | S + developer tests (QA reads and judges adequacy; does not author them) + A with fixture feed |
| UPD-05 | Release-asset trust: only assets on the matching release from the expected repo and URL host are offered; untrusted/foreign asset URLs, lookalike hosts and non-HTTPS URLs are not opened (LINK-01 rules); the button opens the release page, it does not download or run anything | S + A |
| UPD-06 | No auto-install claims or behavior: no code path replaces the bundle, writes outside app support, strips quarantine, spawns shell, or relaunches; UI, README and `docs/install.md` say that updating is manual (download and replace) and that auto-install depends on #89/#15 | S (grep for `Process`, `NSWorkspace.open`, `xattr`, `unzip`, `ditto`, `Sparkle`) + docs read |
| UPD-07 | No credentials: the check does not call `gh`, read tokens, or use `Authorization`; it works with `gh` missing or signed out. Check requests are low-volume (no tight retry loop; periodic checks, if present, are opt-in or clearly user-visible and non-blocking) | S + A with a fake `gh` that fails; observe request count |
| UPD-08 | Independence: an update check, its error or a new-version notice never changes the inbox badge, mascot attention, counts or alert icon, and never blocks monitoring; update status is not mixed into the activity/incident inbox | A + R (state snapshots before and after check) |
| UPD-09 | Privacy and snooze interplay: update notices obey snooze/quiet hours if they interrupt at all; privacy mode does not break the update UI | A |
| UPD-10 | Real-Mac fresh install → update: **not possible in phase 1** (no installer). Mark BLOCKED until a later phase, and say so rather than passing it. Phase 1 does allow: install build N, point check at a fixture feed offering N+1, confirm the UI offers the release page and the app and settings are unchanged | A; limitation recorded |
| UPD-11 | Docs: install guide/README describe the actual experience; no "automatic updates" promise; Gatekeeper/ad-hoc statement unchanged and consistent with #89/#15 | S |

## Run order and handoff

1. Confirm the head SHA and CI conclusion for that exact SHA; merge-from-main status.
2. `swift build`, `scripts/test.sh`, `scripts/build-app.sh`, `scripts/render-check.sh`; record exit codes and artifact SHA-256.
3. Source review pass (tier S: INV-04/05/06, UPD-05/06/07 greps, settings parity INV-08).
4. Runner scenarios and snapshots (tier R/N), then the launched-app pass (tier A) for layout, keyboard, persistence, quiet/snooze with `--start-time`, and the update fault cases.
5. Report: verdict, per-ID results, defects with reproduction to t6f, and an explicit "not verified" list (real VoiceOver, real install/update, notarization, multi-display).

## Known gaps to raise with PM

- The runner has no snooze/quiet-hours action and no update-check action; INV-02 and UPD-02/03 therefore rely on tier A unless the developer adds runner support (developer owns `Sources`).
- UPD-02/03 need an injectable release endpoint or fixture transport in the app; without one the failure paths can only be reviewed from source and unit tests (BLOCKED for functional).
- No Xcode: Accessibility Inspector and real VoiceOver checks are manual; Instruments is unavailable.
