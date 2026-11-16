# PR66 9818b9d QA: queued Refresh and refresh after wake (#60)

**Source review PASS.** The functional label check was **not run**: the driver's pre-launch guard refused to start, and nothing was launched.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task P from PM t61, 2026-11-16.

- **CI:** 43930832600 completed SUCCESS on the exact head `9818b9def60fec23de490885e9b2c3f7e812eac0`.
- **Main-merge resolution:** `9818b9d` merges bc456d1 and main 5573393. Its tree is not the automatic merge, because `MascotWindowLifetimeTests.swift` conflicted between PR66's own copy and main's PR67 version. The resolution keeps **main's version exactly**: `git diff origin/main 9818b9d` is empty for that file. Against main, the PR changes only `AppModel.swift`, `InboxView.swift`, `RefreshCoalescingTests.swift` and `docs/development.md`. `Runtime.loginItemBackend` from PR62 is kept, and the new `wakeCenter`/`wakeRefreshDelay` fields are added next to it.

## Source review

- **Queued Refresh:**
  - **Nothing in flight:** `requestRefresh()` runs `refresh()` immediately.
  - **Poll in flight:** it refreshes the service status and stores **one** `queuedRefreshGeneration`. Repeated clicks overwrite it and never stack.
  - **Running the queue:** `runQueuedRefresh()` runs in a `defer` after the in-flight reply is received (`repositoryTask = nil`). It runs only if nothing else is in flight **and** the generation is unchanged. A source, account or scope change bumps the generation (and had already started its own poll), so the queued request is dropped.
  - **Stale replies:** these return before `repositoryTask = nil`, so the queue waits for the current poll.
- **"Refreshing…" label:** it comes from `repositoryTask != nil` through a `didSet` on a `@Published` value, so it shows only while a repository poll is actually in flight, including periodic polls. Fixtures apply synchronously and never show it. The button stays enabled and a click queues. The label doesn't distinguish "queued"; that is acceptable.
- **Wake:**
  - **Normal launches only:** the observer is installed only when `pollsPeriodically`, meaning not snapshot and not simulated. QA-scenario launches require simulation, so they never observe wake.
  - **Live source only:** `handleWake()` returns unless the data source is `githubCLI` and this is not a snapshot launch.
  - **Debounced:** one `wakeTask`, so wakes within the window are ignored. It sleeps 5 s, re-checks cancellation and the source, then calls `requestRefresh()`, which queues if a poll is in flight.
  - **No storms:** there is no new timer and no change to the poll timer.
  - **Cleanup:** `cleanupScopeSimulation` cancels `wakeTask`.
- **Tests:** 7 tests cover:
  - a queued refresh running once after the reply, and nothing else left queued
  - an immediate run when idle
  - scope and account changes dropping the queue
  - wakes collapsing, and a wake during a poll being queued rather than stacked
  - fixtures not refreshed on wake, and simulated and snapshot launches not observing wake

  **Fail-before** (`pr66-*-developer-evidence/fail-before-stubbed-old-behavior.log`): with the old behaviour stubbed in, `refreshQueued` is false and the request counts are wrong. After the fix: 7/7 pass. The branch full suite fails only on the known in-process `/dev/fd` descriptor flake, which CI runs in isolation.
- **INFO:** each click during an in-flight poll still refreshes the GitHub status immediately. That is the same as the old `refresh()`, not a new storm.

## Functional

- **Wake:** cannot be simulated safely. It needs `NSWorkspace.didWakeNotification` from a real sleep, and only normal launches observe it.
- **Queue:** cannot be exercised through the app without a new hook. The QA runner's `refresh` action calls `model.refresh()`, not `requestRefresh()`.
- **Label:** a hold-then-deliver run on the exact-head artifact could show the "Refreshing…" label. The artifact was downloaded and verified: ZIP `696488fcca46517c9fd2249b8ed11c4f7fe4bd5509e9618a6e1f92ddaa16da81` matches the sidecar, the Info.plist revision is 9818b9d (build 178), and strict codesign passes. However, the driver's guard ("another GitHubPet process exists") **refused before launching**. The Developer's own offscreen `scripts/readme-screenshots.sh` renders from `developer-beta-readme` were running back to back (PIDs 93847, then 95437); QA did not touch them. Following the no-retry rule, nothing was launched and nothing was retried. This can run when the machine is otherwise idle.

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, `refresh-in-flight.json`, `functional-driver.stderr`, `STOP.json`. The helper is `scripts/qa/pr66-9818b9d-refresh-label.py`.
