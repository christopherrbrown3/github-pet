# PR54 0ae70db QA: #41 mascot window retain and popover dismissal

**Source review PASS and offscreen non-regression PASS** at `0ae70db10afe0e17b70397e17fe3c4f5d0dfb61f`.

- **Not done here:** no GUI input. The manual click-away/Esc/Space step needs Chris (`docs/qa/pr54-cf180e2-GUI-PLAN.md`).
- **Session note:** QA (Claude Opus 5.5, `claude-opus-5-5`, task L from PM t61, 2026-11-16) was interrupted by a usage limit after the render run and resumed from the saved evidence. Nothing was downloaded or run twice.

## Head, CI and merge

- **CI:** 43894925739 completed SUCCESS on the exact head (`ci.json`).
- **Merge `f7589e6`:** parents cf180e2 and main b74078b. `git merge-tree` gives `7d4c650…`, identical to its tree, so it was a clean automatic merge.
- **Changes against the merge base:** only `MascotWindow.swift` (+28/-4), the new `MascotWindowLifetimeTests.swift` (+92), and `ScopeApplicationTests.swift` (+4/-1). The earlier CI and descriptor-step changes are already identical on main.

## Source review

- **Retain fix:** `container.onHover` now captures `[weak self, weak container]`, so the container no longer keeps its own closure, hosting view and model alive. `NSPopover.delegate` is weak, so making the controller the delegate creates no new cycle.
- **Close sync:** the controller is now `NSObject, NSPopoverDelegate`, and each summary popover's delegate is set before it is shown. `popoverDidClose` (`nonisolated` plus `MainActor.assumeIsolated`; AppKit delivers it on main) clears `popover`, `summaryInputs` and the anchor only when `closed === popover`.
- **Ordering is safe:** `showSummary` calls `hideSummary()` first, which calls `performClose` and immediately sets `popover = nil`. A synchronous close (Reduce Motion) therefore finds `popover == nil` and does nothing. An animated close arrives after the successor is installed and is rejected by the identity guard. `repositionSummaryIfNeeded` returns early once `popover` is nil, so a dismissed summary is not re-shown, which is the #41 defect.
- **Test-only `0ae70db`:** the PR59 hidden-results app test now waits after `simulateScopeVisibility(.hidden)` before `simulateScopePartial(true)`. That fixes CI 43892593398 on f7589e6, which failed at `ScopeApplicationTests.swift:272`: a refresh while a poll is pending launches nothing, so that poll could miss the partial flag. Correct, and test-only. **INFO:** the same racy sequence lives in **main's** test until PR54 merges.
- **Developer evidence** (`/Users/chris/github-pet-builds/pr54-f7589e6-developer-evidence`, HEAD f7589e6):
  - **Delegate removed:** `systemDismissedSummaryIsNotReopenedByALaterModelChange` reports **3 issues**. `summaryPopover` stays set, and **`isShown` is true after the model change**, which is the exact re-show defect.
  - **Identity guard removed:** `replacedSummarysLateCloseKeepsTheCurrentOne` fails (`summaryPopover === second` is false).
  - **After the fix:** 3/3 pass, and pass again across three repeat runs.
  - **CI-style full suite:** 446 tests in 69 suites pass.
  - The retain-cycle fail-before (`weakContainer` alive on main) is reported in the PR body.
  - A run on a stale binary was correctly labelled `INVALID` and excluded.

## Offscreen non-regression (exact-head artifact)

| Item | Value |
|---|---|
| Artifact | `GitHubPet-app` 14239816076 from CI 43894925739 (head_sha 0ae70db…) |
| ZIP SHA256 | `1a3035a1f9525167ded9bde271fa661a502186236872d1b7cc8ed901e3ecb906` (`shasum -c` OK against the sidecar) |
| Binary SHA256 | `f5b307c62cc263ab7554673568ef77866a24cb62e538aee498e0f434d37ba264` |
| Info.plist | `GitHubPetSourceRevision` = 0ae70db… (**verified equal**), build 146. Strict codesign PASS. |

**Method:**

- **Script:** the repository's `scripts/render-check.sh` at 0ae70db, run against the artifact binary from a **scratch copy**. The only change in the copy removes the timeout `kill $pid`, so a timeout would leave the app intact and send no signal; it did not time out.
- **Launch:** the script itself uses `--defaults-suite <temporary absolute-path plist> --gh --clock-offset 86400 --render-snapshots <dir>` with a gh trap. Offscreen only: no GUI input, no CUA, no normal launch.
- **Preferences:** QA's own hash-only snapshots before and after are **equal** (`prefs-before/`, `prefs-after/`).
- **Protected app:** PID 31897 kept its original start time (`saved31897-*.txt`). No QA app was left running.

**Result:** `render-check: all checks passed`, exit 0, **117 `ok`**, no FAIL or SKIP lines (`render-check.log`). The checks include:

- gh never launched and the seeded preferences were untouched
- Inbox and Settings heights
- 11 hover placements
- the hover-growth probe on the real mascot window controller, which goes through `showSummaryNow`, the new delegate path
- hover failure diagnostics
- near-touch and resize lanes

**Compared with CI's own `render-check` report for the same head:** all 14 hover lines have identical verdicts (side, overlap 0, lane clear, on-screen, meets-target), and the growth line is identical. Only the screen geometry differs: this Mac is 1920×961 and the CI runner was 1024×681.

## Limits

- **Real dismissal not exercised:** system-initiated dismissal (a click elsewhere, Esc, a Space change) has no offscreen or simulation hook. That is covered by the Developer's real-controller tests with fail-before evidence. Live confirmation is the optional manual step with Chris.
- **Not checked:** live memory or leak profiling of the running app, VoiceOver, and Intel.

## Evidence committed

`ci.json`, `artifact-metadata.json`, `render-check.log`, `render/report.txt`, `ci-render/report.txt`, `prefs-{before,after}/preferences.json` and `saved31897-{before,after}.txt`. The ZIP, the extracted app and the PNGs stay local.
