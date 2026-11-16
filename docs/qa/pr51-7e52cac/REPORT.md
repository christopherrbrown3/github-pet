# PR51 7e52cac QA: source review PASS, functional HOLD (CI red)

QA: Claude Opus 5.5 (`claude-opus-5-5`), task D from PM t61, 2026-11-16.

- **Head:** `7e52cacd19d946c564fbd59ce89d44485dce8d4c`. It adds four commits on top of e57d1f3:
  - `34a6e6e`: cancellation bridge for validation and discovery.
  - `c2b2d1f`: compare discovery pages by viewer ID only.
  - `a685077`: require a genuine boolean for `hasNextPage`.
  - `7e52cac`: give a reason when a clean page has a malformed connection (the earlier LOW-4).
- **Verdict:** the source review passes with no findings above INFO. The functional part did **not run**, because CI 43879864048 completed with **failure** on this head.

## 1. Independent source/diff review (`git diff e57d1f3..7e52cac`)

| Check | Result |
|---|---|
| Continuation resumes exactly once | `ScopeEditor.offPool(budget)` wraps `withCheckedContinuation` in `withTaskCancellationHandler`. Only the Dispatch block resumes the continuation, and `onCancel` only calls `budget.cancel()`. If the Task is already cancelled, `onCancel` runs straight away, so the first `check()` throws. |
| Deadlock / lock order | `CommandBudget.cancel`, `isCancelled`, `check` and `reserve` each take the same non-recursive NSLock, briefly and without nesting. `check()` releases the lock before it throws. `onCancel` never runs while that lock is held. No lock-order cycle. |
| Cancelled run fails closed | `check()` throws `.cancelled` when the latch is set or `Task.isCancelled` is true. `ProcessCommandRunner` polls at most every 50 ms, then terminates the child, allows a 2 s grace period, and sends SIGKILL. A budget cancelled before launch starts no child. A cancelled discovery ends with `finishOpen(.cancelled)`: open categories become partial or failed, never exhausted or capped, and the epoch guard still discards the reply. A cancelled validation ends with `.failed(.cancelled)`, which the revision guard discards. |
| Replacement budget independent | `budget()` builds a new budget for each validation or discovery run, and the latch is never shared or cleared. |
| Process reaping | Tested with a real `/bin/sh` and `sleep` child: after cancelling from another thread, `kill(pid,0)` returns ESRCH. |
| ID-only identity | Pages are compared with `$0.account == viewer.account`, so a login rename keeps the hints. A real ID change still gives `.identityMismatch`. |
| Strict `hasNextPage` | A `CFBoolean` check, matching `ScopedGitHub`. JSON 0 or 1 now counts as a malformed connection, giving partial or failed rather than exhausted or capped. |
| LOW-4 reason | A malformed connection on an otherwise clean page now sets `failure = .malformedResponse` when no other failure is recorded. |

Developer before/after evidence is in `/Users/chris/github-pet-builds/pr51-7e52cac-developer-evidence`. The base HEAD recorded for each fix matches. Each fix fails before and passes after:

- **Fix 1, editor tests (fail on behaviour):**
  - Discovery: the cancelled run fetched 3 pages instead of 1, `old.failure` was nil, and the result was capped.
  - Validation: it recorded `malformedResponse` instead of `cancelled`, and the child ran for 3.07 s, against 0.06 s after the fix.
  - The core `BoundedCommandTests` only failed to compile before, because the API did not exist yet.
- **Fix 2:** a login rename produced identityMismatch.
- **Fix 3:** numeric `hasNextPage` certified the category.
- **Fix 4:** `failure` was nil.

After the fixes, all of these pass, a 3× repeat passes, and the local full run passes 415 tests in 66 suites.

INFO notes, not findings:

- The simulated held validation (`ScopeAccessSimulation.validate`) polls only `remaining` and `holdLimit`, not the latch. A held simulated thread therefore stays until it is released, although its reply is still discarded. This is simulation only.
- Teardown of gh's grandchild processes is unchanged; only the direct child is killed, as before.

## 2. CI 43879864048: FAILURE, functional runs not started

The `build-and-test` job fails at the Test step: 414 tests, 2 issues (see `ci-43879864048-failure-excerpt.txt`).

- **Failing test:** `latchedBudgetCancellationReachesWorkWithoutATaskContext`, at `BoundedCommandTests.swift:147` (`waitForGroup` timed out after 2 s) and `:148` (receipt nil, not `.cancelled`). This test is new in 34a6e6e.
- **Likely cause:** the test sends `budget.check()` to `DispatchQueue.global()` and waits only 2 s. Under CI's parallel test load, that shared global queue apparently did not start the block within 2 s; the failure looks like starvation or timing.
- **Local result:** the same test passes, but it fails on CI.
- **Sibling test passes on CI:** the real-child reap test, which runs on its own labelled queue.
- **Assessment:** this is a test-robustness defect, not evidence that the latch fails. The test is still red, though, and it is Developer-owned.
- **Suggested fix:** use a dedicated queue or Thread, or wait longer.

Following the dispatch rule (run functional checks only after a green CI on this head), I did not download the artifact and did not launch the app. No app, preference or gh actions were taken, and protected PID 31897 was untouched.

## Planned functional run once a green exact-head CI exists

Use the existing `scripts/qa/scope-artifact-functional.py` with the explicit simulation flag first, a gh tripwire, hash-only preference before/after snapshots and the PID 31897 guard. Run only these scenarios:

- `settings-discovery-partial`
- `settings-discovery-identity-mismatch`
- custom `discovery-roundtrips.json`: A→B→A and CLI→Fixtures→CLI (identical to e57)
- `settings-validation-failure-keeps-active`: built-in; it includes a `demo-renamed` target-rename validation through the new off-pool validation path

Simulation cannot cover a viewer-login rename during discovery without new hooks, so that stays with the Developer's regression test (fix 2).
