# Monitoring scope: application slice A

This slice connects the accepted scope client to the application. The ordinary Settings scope editor, discovery and live draft validation follow in PR B; this is not the complete #30 feature.

A repository scope session restores the last-known github.com viewer's stored selection before its first fetch. That request includes the expected viewer node ID. Whenever no valid saved selection is known (an unknown viewer, or a corrupt record while monitoring is paused), the request is **identity-only**: it asks for the viewer's node ID and login and runs no search aliases, so it fetches no rows and costs no search. That still detects account switches. A resolved valid selection is then fetched with a request bound to that viewer. A corrupt record stays an explicit configuration error, never empty and never Everything. Repair or a validated Apply resumes full scoped polling with a silent baseline. A different viewer also discards the submitted scope's reply and restores that viewer's own selection. One cycle permits at most one follow-up, with the **same 20-second monotonic budget and aggregate 2 MiB output allowance**, plus the transport's existing bounded cleanup. Further identity churn or budget exhaustion is an explicit failure, never a fallback to Everything.

The MainActor session uses generation plus request serial guards. Apply persists only for the expected identity/generation, cancels the old task, clears repository rows/unseen/baseline/attention, and starts a silent baseline. Future Settings code must validate access before invoking this commit seam. Scope/account resets never call the full data-source switch or reset public incidents. Clips retain repository/service origin and their original time bounds (at most one per origin); removing repository attention preserves concurrent service attention without restarting it. Natural completion settles the whole batch rather than promoting a hidden source clip into a gesture backlog. A genuine data-source switch still resets both sources.

Unknown, invalid identity, corrupt selection and failed bootstrap stay errors/loading; they cannot become a verified empty inbox. Scoped partial/error/cap details reach a generic quality message. Proven partial rows use the existing engine's silent recovery rules. Inbox scope summaries use mode and target counts, without target names, including when privacy is off. Demo uses its own selection record. The new last-viewer record contains only supported host and opaque viewer node ID, not a token or login.

## Offline functional QA in the actual app

Run the exact-head CI app binary with the explicit flag:

```sh
/path/to/GitHubPet.app/Contents/MacOS/GitHubPet --simulate-monitoring-scope
```

The flag is **off by default**. It forces a fresh randomly named `dev.github-pet.scope-simulation.*` defaults domain that lives only in memory (never written through cfprefsd or to `~/Library/Preferences`), seeds only invented accounts/targets, uses no gh process or network (including public status), and labels the app Demo and Simulated. Caller defaults-suite overrides cannot select a real account store. Quitting clears this in-memory domain; no simulation plist is ever created, so none can be left behind. Periodic repository polling is disabled; use Refresh and the **Simulated scope** menu in the Inbox. The normal data-source picker can exercise source changes; return to GitHub CLI within this simulated launch for account scenarios. Even there both sources remain offline. Normal launches have no simulated controls, seeded accounts or fixture transport.

Account/reload/apply controls are disabled when the source is Fixtures; delivering an already-held reply and public incident controls remain available to verify isolation. Teardown invalidates the repository session before releasing held replies, so deleted temporary defaults cannot be recreated by a late callback.

The menu reports account, request count, held replies, last requested scope/expected account, and discarded late replies. Invented rows show their titles: privacy mode is hidden in Beta 4 (#94, kept behind `FeatureFlags.privacyMode`) and effectively off, and the scope summary itself remains generic. Keep one QA app running at a time and preserve the user's installed app/settings. These steps are for functional observation, not a request for QA to author unit harnesses.

- **Restore before display:** initial launch is saved A Selected (`demo-a`), one row, no unseen/gesture. The last request is Selected/expected A. “Reload saved A (unknown viewer)” first sends an identity-only request (`IdentityOnly`, no search aliases), then requests bound Selected; `demo-outside/pet` must never appear as active rows during that restoration. “Reload saved A (known viewer)” requests Selected directly.
- **A→B→A:** choose Account B, then A. B restores its saved explicit `demo-b/pet` repository; A restores its organization. Each settles with one row and no new alert. Accounts are simulated, not changes to `gh auth`.
- **Late reply after Apply:** hold the next repository reply; wait until the menu says one held. Apply Everything (simulated validation), then inject a new row. There should be three rows and one new unseen event. Deliver held replies: discarded count increases and the older one-row Selected result cannot replace the new rows/attention. Refresh unchanged must not announce again. Release within the bounded 20-second cycle.
- **Corrupt saved Selected:** corrupt saved A and reload. It shows configuration error with no verified-empty state or broadening. While paused, reload and every Refresh send only `IdentityOnly` requests bound to A with no search aliases (`scopeSimulation.requests[].searchAliases` is empty). Switching to account B is still detected and shows B's own selection; switching back to A pauses again. Repair saved selections restores the one-row Selected baseline silently. The `corrupt-saved-selected` runner scenario records each of these steps.
- **Partial→recovery/new-once:** start with repaired selections. Set partial replies and inject a row: partial count, no new gesture. Complete replies/recover: silent baseline. Inject another row: one new unseen event/gesture, unchanged Refresh does not replay it.
- **Incidents preserved:** inject a major public incident in the Simulated scope menu, then Apply Everything or Selected. Its incident rows/unseen marker/burst and still-active service clip retain their original timing. Scope Apply does not refetch/reset public status. Existing motion/quiet/snooze controls can intentionally suppress gestures without changing source truth.
- **Privacy and source change:** scope header contains counts, not target/account names. Hold a repository reply, switch the data-source picker to Fixtures, deliver it: it is discarded and Demo keeps its separate scope. Return to GitHub CLI to restore the simulated account's selection. Real account selections are never written.

## Scenario runner (no screenshots or clicks needed)

The same build can drive these scenarios itself and write what a user would see:

```sh
/path/to/GitHubPet.app/Contents/MacOS/GitHubPet --simulate-monitoring-scope \
  --qa-scenario stale-reply-after-apply --qa-output ~/qa-runs/stale-reply
```

- **Opt-in and isolated.** `--qa-scenario`/`--qa-output` without `--simulate-monitoring-scope` (or together with `--render-snapshots`) are refused with exit 2 before any model or defaults domain exists, and nothing is written. Same isolation as the flag above: throwaway domain, invented accounts, no gh process or network, labelled Demo/Simulated.
- **Output safety.** The output path is resolved once (realpath of its deepest existing ancestor), then opened by walking from `/` one component at a time with `openat(O_DIRECTORY|O_NOFOLLOW)`. Missing components are created with `mkdirat`, every directory on the way must be owned by you or root, and the opened directory's real location is checked against the protected list again. A symlink swapped into any ancestor after validation is therefore refused, never followed. A missing directory is created; an empty one is used. A non-empty directory is accepted only if it holds the runner marker `.github-pet-qa-runner` and nothing but runner files (`step-NN-*.json|png`, `runner.json`), which are replaced. Every entry must be a single-link regular file: a hard-linked or symlinked marker or step file, or a runner-named directory, is refused. After validation, all output goes through one `O_NOFOLLOW` directory descriptor. Writes use a fresh exclusively created temporary inode and atomic replacement, so even a destination swapped after validation cannot cause an outside inode to be truncated. Cleanup unlinks single-link regular files only and never recurses. Anything else, plus `/`, home, `~/Library`, `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/etc` and the app bundle, is refused. Relative paths resolve against the working directory.
- **Built-in scenarios (PR A):** `restore-before-display`, `account-a-b-a`, `stale-reply-after-apply`, `corrupt-saved-selected`, `partial-recovery-new-once`, `incidents-preserved`, `privacy-summary`, `demo-isolation`, plus `hidden-results` (#35). Or pass a path ending in `.json`: `{"name": "a1", "steps": [{"action": "hold", "count": 2, "label": "hold-two"}, ...]}`. Labels match `[a-z0-9][a-z0-9-]{0,39}`; up to 99 steps.
- **Steps** call exactly what the matching control calls (Simulated scope menu, Inbox Refresh, Settings toggles and source picker; with #94 shown, also Inbox Show details):
  - Scope and replies: `account` {`account`: A|B}, `apply` {`scope`: selected|everything}, `hold` {`count`: 1-8 = the next N replies, `refresh`: true = trigger one now}, `deliver-oldest`, `deliver-newest`, `deliver-all`, `inject-row`, `partial` {`on`}, `visibility` {`mode`: complete|hidden|hidden-only|capped} (#35 search fixtures), `refresh`, `mark-seen` (what closing the Inbox does).
  - Saved selections: `reload` {`viewer`: known|unknown, `account`: A|B}, `corrupt` {`account`} (no reload), `corrupt-reload`, `seed` (no reload), `repair`.
  - Incidents: `inject-incident` {`tier`: minor|major}, `resolve-incidents`.
  - Settings: `privacy` {`on`} and `show-details` {`on`} (privacy mode and Show details are hidden in Beta 4; these steps write the stored value or do nothing, see below), `reduce-motion` {`on`}, `source` {`source`: fixtures|gh}, `open-settings` (also renders Settings).
    `privacy`, `snooze` and `quiet-hours` write the *stored* setting even while #94/#95/#107 hide those features, which is how QA reproduces an upgrade from an earlier beta. Each step's `settings` block records `features`, `privacyMode` (stored) and `effectivePrivacyMode`; `suppression` reports effective snooze and quiet hours. Built-in `hidden-features-upgrade` runs that case end to end.
  - Time and capture: `clock-set` {`time`: ISO 8601}, `clock-advance` {`seconds`: 0-86400}, `wait-real` {`seconds`: 0-60}, `capture`.
  - `quit` must be the last step.
- **Time.** The app clock starts at 2026-11-15T12:00:00Z and moves only on `clock-set`/`clock-advance`, so clips and bursts are reproducible. Repository budgets and held replies keep their real 20-second bound: use `wait-real` to let a held reply time out.
- **Output.** Step 00 is the launch state. After each step the runner waits until every simulated request has been received or is held (30-second harness bound), ticks once, then writes:
  - `step-NN-<label>.json`: Inbox header (scope summary, quality text, status, hint, badge), visible rows with stable ids and privacy-applied text, unseen/clip/burst/marker/mascot state, service incidents, settings, active scope identity/generation, the request log (scope, targets, expected account, generation), held/received/discarded counts, simulated account and defaults domain name.
  - `step-NN-<label>-inbox.png` and `-mascot.png`, plus `-settings.png` for `open-settings`. These are offscreen renders of the app's own views (no Screen Recording or composited desktop). The mascot is drawn at the scenario clock (`mascotRenderedAt` in the JSON), so its pose and clip/burst phase match the record. Each PNG must decode, or the run fails as a harness error.
  - `runner.json`: the scenario summary. After `quit`, it also reports held replies at quit, late replies received after cleanup, keys left in the in-memory domain, and whether a plist exists for it (it never should).
- **Exit codes.** A non-zero exit means a harness error only: 2 for a refused flag or invalid scenario, 1 for a step that would not settle or an output write failure. The runner never judges pass or fail.

## Matches hidden from your account (#35)

GitHub's search `issueCount` can include items the viewer can't read. Each search alias (and the legacy client's two searches) is classified:

| Search result | Shown as |
|---|---|
| A full page (30) with more matches, or `hasNextPage` | **Partial**, as before ("Scope result limit reached"). |
| Fewer nodes than a page, a larger count, no next page, in a fully clean response | Complete for visible results. The rows show, with an informational note (no warning symbol, Partial badge or mood change): "3 matching items aren't visible to your account". |
| The same, with zero visible rows | "No visible items · 3 matches hidden from your account", badge `0`. This is never the verified-empty "All clear" state. |
| Any error, nonzero exit, malformed or missing node or source, or identity issue | **Partial/Error** exactly as before. The hidden count is dropped and the alias counts as capped. |

Counts only: never repository or target names. Identity-only replies carry no search aliases and never contribute a count. In simulated mode, the **Search visibility (#35)** submenu (or the runner's `visibility` step) sets the review searches to hidden (+3), hidden-only (0 nodes, 3 hidden) or capped. Combine it with **Partial replies** to see the error case. The `hidden-results` scenario walks through every row of the table; each step's JSON has `inbox.hiddenResults` {`count`, `note`} and `simulatedVisibility`.

## Developer evidence

Developer owns the committed pure session/clip/budget tests and the new native AppModel test target. Tests cover saved/unknown bootstrap, A→B→A, reverse-order Apply/source replies, stale commit guards, corrupt configuration, partial recovery/new-once, incident state/unseen/burst/clip preservation, generic summaries, launch isolation, shared cycle byte exhaustion and no preflight after deadline. Manual GUI, pointer, VoiceOver, physical Intel and clean-Mac Gatekeeper validation are separate functional evidence; unit assertions and offscreen renders do not establish them.

Unit fixtures explicitly control domain time, motion and the in-memory deadline clock; one case expires the initial request and proves the recovery baseline stays silent before a later genuinely new event. Another uses the actual NSWorkspace motion provider through the ordinary fixture-to-AppModel path. The private fixture clock cannot be used by real subprocesses; public budgets retain the system monotonic20s maximum and collection-time byte cap.
