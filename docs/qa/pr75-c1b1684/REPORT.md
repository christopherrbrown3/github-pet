# PR75 c1b1684 QA: deployment approvals, #10 slice 2

**Feature source review PASS, with two LOWs.** The final-head merge and CI check is **pending**: t62 is merging main, now d42da4a. No functional run: Actions can't be simulated.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task AE from PM t61, 2026-11-17. No app was launched.

- **Head and CI:** `c1b168421dc3a381dcf20a72a49229dd29b745fd` (base 55ff7a3). CI 44152574631 completed SUCCESS. The gate on c1b1684 (`deployments-gate`) passes 571 tests in 93 suites, and the descriptor test passes in isolation.
- **Fail-before:** compile-only (new types), as expected for a new feature. After: 35 core tests and 3 app tests pass.

## Checked against the brief

| Point | Source | Result |
|---|---|---|
| Separate opt-in toggle, off by default, in "GitHub Actions" | `watchDeploymentApprovals = false`; `decodeIfPresent ?? false`; Settings section renamed "GitHub Actions" with two toggles | ✔ |
| REST `actions/runs?status=waiting`, `per_page=10`, per watched repository | `WaitingRunsPlan`: `api --hostname github.com -X GET repos/<owner>/<name>/actions/runs -f status=waiting -f per_page=10`. The fields become query parameters on a GET. Each run is validated: `status == waiting`, a node ID, a run URL under this repository's `/actions/runs/` | ✔ |
| One batched, viewer-bound GraphQL `pendingDeploymentRequests{currentUserCanApprove}`, only when runs wait | `PendingRequestsPlan` uses `node(id: $runN)` with variables; it is built only when `runs` is non-empty; `currentUserCanApprove` must be a genuine boolean | ✔ |
| Approvable → actionable `deploymentApproval` row that opens the run and **never approves** | ID `deploy:<run node>`, so a new attempt doesn't re-announce; the URL is the run's `html_url`. A whole-Sources grep finds **no** `POST`/`PUT`/`PATCH`/`DELETE`/`--method`/`pending_deployments`; `clientQueriesEachRepositoryThenOnceForAllWaitingRunsAndNeverWrites` asserts that no call contains POST, PUT, `pending_deployments` or `approve ` | ✔ |
| Waiting on others → count line only | `deploymentsWaitingCount`, an hourglass "N deployment(s) waiting on other reviewers" ("At least" while incomplete); never rows, badge or mood | ✔ |
| Own 20 s budget; caps → Partial | `makeBudget()` per part when it starts; more than 10 waiting runs or more than 10 requests per run is capped; REST errors, rate limits and denials make that repository unavailable | ✔ |
| Last-known on errors | a separate `deploymentsLastKnown` with the `deploy<i>` alias; the quality line counts each repository once across both parts | ✔ |
| Coverage key includes the watched parts (silent seed) | the Actions key is account + `failures`/`+deployments` + watched qualifiers; turning on either part re-keys, giving a silent seed (`turningOnAnotherActionsPartReseedsSilently`) | ✔ |
| Identity mismatch | the GraphQL viewer must equal the expected account; `combiningActions` treats different viewers as an identity mismatch; a REST-only result with no waiting runs is bound to the inbox viewer from the same cycle | ✔ |
| Privacy | the title "<workflow> is waiting for your approval to <env>" and the repository follow `PrivacyText`; the generic label is "Deployment approval"; the waiting line shows counts only | ✔ |
| No argv interpolation | GraphQL uses variables only. The REST path contains the validated `owner/name` (`MonitoringTarget`: ASCII, no slashes) as one argv element, with no shell | ✔ |

## Findings

- **LOW-1 (copy):** `ActionsWatch.qualityLine` still starts "Workflow failures: …" when only the **deployments** part failed, for example "Workflow failures: 1 repository unavailable…" while only deployment approvals are watched. Suggest "GitHub Actions: …".
- **LOW-2 (copy):** a run held only by a **wait timer**, with no required reviewers, has `currentUserCanApprove == false`, so it's counted as "waiting on other reviewers", which is wrong for a timer. Rare; consider excluding wait timers or rewording to "waiting on others".
- **INFO:** turning on the deployments part re-keys all GitHub Actions rows (including workflow failures), so they re-seed silently. Unread dots on existing failure rows clear, and anything first appearing in that refresh is absorbed silently. This matches the slice-1 behaviour and is documented.
- **INFO:** the deployments waiting line is shown independently of the inbox's data state, unlike PR71's authored line, which needs usable data. That's harmless.

## Checklist

`docs/qa/beta-smoke-checklist.md` §16 now covers slice 2 (step 8): toggles off by default; turn on without a burst; a new waiting run you can approve alerts once and opens the run page; approval happens only on GitHub and the app never approves; runs you can't approve appear only in the count line; approving removes the row. It also updates steps 5 and 6 for the PR72 MED-2 and PR73 behaviour: a separate Actions line, the inbox staying complete, and the "GitHub Actions" wording.
