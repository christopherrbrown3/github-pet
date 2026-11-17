# PR72 d1345e8 QA: Actions workflow failures, slice 1 (#10)

**Source review PASS with one MED (a PM decision) and two LOWs. No functional run:** the simulation can't produce Actions results, and the renderer doesn't capture the new Settings section, both without new hooks.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task Y from PM t61, 2026-11-17. No app was launched.

- **Head and CI:** `d1345e82a7e433858f97153586541c0043e37323` contains current main ca4c801. CI 44139307181 completed SUCCESS on the exact head.
- **Changes against main:** `ActionsMonitor.swift` (new), `WorkflowFailuresSection.swift` (new), `AppModel.swift`, `Settings.swift`, `Models.swift`, `InboxView.swift`, `SettingsView.swift`, the README and tests.

## Checked against the approved design

| Design point | Source | Result |
|---|---|---|
| Opt-in toggle, off by default | `PetSettings.watchWorkflowFailures = false`; `decodeIfPresent ?? false`; Settings section at the end | ✔ |
| Live gh and Selected repositories only, with an honest line otherwise | `actionsJob` requires `.githubCLI`, a non-identity-only request and `coverage == .repositories`. The notes say "watched with the GitHub CLI source", "select repositories…" or "…not for selected organizations"; simulated launches never create a job | ✔ |
| One viewer-bound GraphQL query per poll, after a usable inbox reply, with its own 20 s / 2 MiB budget | `poll(…, actions:)` runs only when `result.viewer != nil && successfulSources > 0`, with `expected = request.expectedAccount ?? result.viewer`; `makeBudget()` starts when the Actions query starts | ✔ |
| Default-branch HEAD check suites from the Actions app only | `defaultBranchRef.target … checkSuites(first: 20, filterBy: {appId: 15368})` | ✔ |
| COMPLETED with FAILURE, TIMED_OUT or STARTUP_FAILURE | `failingConclusions`; cancelled, skipped, neutral and stale are ignored | ✔ (LOW-2) |
| Critical only when `creator == viewer`, else actionable | `.ciFailure` (critical) vs the new `.workflowFailure` (actionable); same label and icon | ✔ |
| ID per suite: a re-run doesn't re-alert, a new failing commit alerts once | `actions:<checkSuite id>` | ✔ |
| Caps, per-repo denied/SAML, rate limits and failed exits are Partial, with PR64 messages | `total > nodes` → capped; a null repo → targetUnavailable; an `errors` member → rateLimited / accessDenied / graphQLError; a failed exit keeps readable repos plus `.accessDenied` or `.transport`; stderr is only classified, never displayed | ✔ |
| Viewer mismatch → identityMismatch | in the parser (`expectedAccount`) and in `mergingActions` (inbox and Actions viewers differ) | ✔ |
| Generation guards | the merged result goes through the existing `receiveRepositoryPoll(request:)`; the budget check sees cancellation of the detached poll task | ✔ |
| PR63 baseline and PR71 `waitingOnOthers` carried | `mergingActions` keeps `waitingOnOthers` (d1345e8; fail-before 5 issues, then 15/15) and zeroes `hidden` when Actions has issues | ✔ |
| Privacy | the title "<workflow> failed on <branch>" and the repository follow `PrivacyText`; the Settings note shows counts only | ✔ |
| No argv interpolation | owners and names only as `-f ownerN=…`/`nameN=…` variables; only constant numbers in the query text | ✔ |
| No approval or mutation calls | a single `api graphql` **query**; the copy says "nothing is re-run or changed" | ✔ |

- **Evidence:** the new-feature fail-before is compile-only (`issue10-slice1-evidence/before.txt`: the types didn't exist), with 14/14 after. The waiting-count carry has a behavioural fail-before (5 issues, then 15/15). The gate on the exact head (`pr72-gate2-evidence`, HEAD d1345e8) passes 548 tests in 89 suites, the descriptor test passes in isolation, and no new preference files appeared.

## Findings

- **MED-1 (PM decision): turning the toggle on announces failures that already exist.**
  - **Cause:** the baseline key covers source, account and scope, not `watchWorkflowFailures`. The toggle only calls `requestRefresh()`, and the engine compares against the previous complete snapshot.
  - **Effect:** every failing suite already on the default branches becomes a new event (unseen, attention gesture). One the viewer triggered (`ciFailure`) also sets the mascot **urgent**.
  - **Why it's a decision:** the brief says enabling "surfaces critical items and the urgent mascot". A persistent urgent mood while your own failure exists matches that, but the AGENTS rule is "Initial sync establishes a baseline; animate genuinely new comparable events once". By comparison, a scope change, or PR71's `categoriesVersion`, re-baselines silently.
  - **Suggestion:** include the toggle (or the Actions coverage) in the baseline key, or seed the first Actions result silently. Existing failures would then show as rows, with mood urgent if critical, but would not announce.
  - **Test gap:** no test covers enabling the toggle.
- **LOW-1: earlier failures disappear during an Actions error cycle.** The brief says Actions results are "kept across a failed cycle with a stale label". An Actions error makes the snapshot Partial (so never "no failures"), but `mergingActions` only adds that cycle's items, so the earlier failure rows **disappear** for the error cycle instead of staying with a stale label. Honest (Partial, "N+"), but less useful.
- **LOW-2: unknown enum values are skipped, not flagged.** An unknown `status` or `conclusion` value is skipped rather than marking the row malformed, whereas PR71 treats unknown enums as Partial. A future GitHub failure conclusion would be silently ignored. Consider failing closed on values outside the known sets.
- **INFO:** with Actions enabled, a poll's task can take up to about 40 s (inbox 20 s + Actions 20 s); "Refreshing…" stays visible for that time.

## Functional

- **No Actions results in simulation:** a simulated launch never creates an `ActionsJob` (`simulated ? nil : actionsJob`), and the scenario runner has no Actions action. Simulation therefore can't produce Actions rows without a new hook.
- **No capture of the new section:** the offscreen renderer captures only the top of Settings (`settings`), `settings-scope-long` and the README crops. `WorkflowFailuresSection` sits at the bottom, so no render shows the toggle without a new hook.
- **Coverage instead:** default-off and the honest notes are covered by `settingIsOptInAndOldSettingsDecodeOff` and `settingsNoteIsHonestAboutWhatIsWatched`.
- **Live check:** suggested for the beta smoke checklist. Turn the toggle on with a selected repository whose default branch has a failing run, and observe whether existing failures announce (MED-1).
