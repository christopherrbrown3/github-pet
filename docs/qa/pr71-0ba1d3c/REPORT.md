# PR71 0ba1d3c QA: authored-PR attention (#9)

**Source review PASS. Functional PASS on the exact-head artifact. MED-1 is reproduced in the app.**

QA: Claude Opus 5.5 (`claude-opus-5-5`), task W from PM t61, 2026-11-17.

- **Head and CI:** `0ba1d3c8ec94c252bed131f762dc708ba84bd6fc` contains current main d1a05ac. CI 44132501861 completed SUCCESS on the exact head.
- **Artifact (downloaded and verified):** ZIP `88e5aa2a80215c56d85b0c503b26654143fcd80efca58cba1549f988c47d91ba` matches the sidecar. The revision is 0ba1d3c (build 216), and strict codesign passes.

## Source review against the approved design

| Design point | Source | Result |
|---|---|---|
| Needs action = CHANGES_REQUESTED, CONFLICTING, or rollup FAILURE/ERROR | `AuthoredAttention.init` | ✔ |
| Mergeable UNKNOWN goes to the waiting line, not Partial | UNKNOWN is a known value with no reason, so the PR is waiting and re-evaluated on the next poll | ✔ |
| Drafts are non-alerting | `isDraft` makes it `.waiting`, after full validation, so a malformed draft is still Partial | ✔ |
| Malformed or unknown enums are Partial | a strict `CFBoolean` `isDraft`; known-value sets for reviewDecision (or null), mergeable and rollup state (or null); a 40-hex lowercase OID; `commits.count ≤ 1`. Otherwise `nil`, which gives `.malformedRow` | ✔ |
| ID = node + reasons + head OID for checks | `authoredPullRequest:<node>:<changes,conflict,checks@oid>`, always in the same order | ✔ |
| No re-announce on churn | the key ignores `updatedAt` and the title | ✔ |
| Baseline key v2, silent re-baseline on upgrade | `BaselineKey` includes `c\(categoriesVersion)` (2), so an old record mismatches and the next snapshot re-baselines silently | ✔ |
| Waiting line never in badge or mood | `waitingOnOthers` gives `authoredWaitingNote` (Inbox label only); waiting PRs never become items. It shows only beside usable data, "At least" while Partial, and resets on account, scope or source change | ✔ |
| Privacy hides titles and repos | the existing `PrivacyText` rules; the `attention` text is fixed wording with no names, so it is shown in privacy mode | ✔ |
| Strict parsing and caps | the same row validation as the other categories (typename PullRequest, `/pull/` URL path, inside the target); 30 per category with a cap, so Partial; a PR needing action in one inclusion is never also counted as waiting | ✔ |

- **Fail-before** (`/Users/chris/github-pet-builds/pr71-0ba1d3c-developer-evidence`): with the authored category removed, 10 of 17 authored tests fail (33 issues). The pure enum tests don't depend on the table, so they pass either way. After the fix: 17/17 pass, and the full suite passes 529 tests with no new preference files.
- **MED-1 (design consequence):** the ID contains the whole reason set, so **losing** a reason also produces a new ID, which is announced once as a new item. Examples:
  - checks get fixed while changes are still requested ("changes,checks@…" becomes "changes")
  - a push turns failing checks into pending

  The user gets an "attention" alert for a PR that improved, and a typical fix-and-push cycle can alert twice. Suggested fix: treat a needs-action PR as new only when a reason component (or a new failing head) wasn't seen before for that node. For example, observe one tracker key per reason component, or compare reason sets per node.
- **LOW:** if two inclusions return different reason sets for the same PR (a race between searches), two rows with different IDs can appear. This is rare.
- **INFO:** the authored kind has `actionable` severity, the same as review requests, and the generic label "Your pull request".

## Functional (exact-head artifact)

PM confirmed that PID 15015 (`/Users/chris/github-pet-builds/main-0f73723-beta-preview/GitHubPet.app`, Chris's own launch, started Nov 16 14:41:47; embedded revision `c47d8b4`) replaces 31897 as the protected app.

- **Driver guard update:** `scripts/qa/scope-artifact-functional.py` now takes `--protected-pid`/`--protected-path` (default 15015 and its path). Before launching it requires the protected app to be running at that path, refuses if any other GitHubPet process exists, and records whether PID, start time and path are **unchanged** afterwards.
- **Launches:** two artifact-only launches, each with `--simulate-monitoring-scope` first, existing runner `authored` and `privacy` actions only, and in-memory throwaway suites. gh tripwire 0, protected app **unchanged** both times.

**Run 1** (`functional-run/`, `authored-attention.json`, 7 steps):

| Step | Observed | Verdict |
|---|---|---|
| changes-requested | Needs-action row "Demo · Your pull request · Changes requested", unseen, mood attention, one clip. Waiting line: "3 of your pull requests are waiting on others or being checked by GitHub" (approved, draft with conflict, still-checking UNKNOWN). Badge 2, so the waiting PRs are not counted | PASS |
| churn (updatedAt only) | Same ID and state, no new event | PASS |
| checks-failing (new head OID) | New ID `…:changes,checks@bb…`, row unseen: **one** new event. Reason text "Changes requested, Checks failing" | PASS |
| back to changes-requested | ID `…:changes` was **already seen** in step 1, so there is no event (unseen 0, mood idle) | PASS (this is not MED-1; see run 2) |
| privacy off | Titles and `demo-a/pet` appear; with privacy on, only "Your pull request · <reason>" showed | PASS |
| authored off | Row and waiting line gone | PASS |

**Run 2, the MED-1 reproduction** (`functional-med1/`, `authored-med1-repro.json`):

1. The first sighting of the PR is checks-failing, giving `…:changes,checks@bb…`: unseen, mood attention.
2. Then changes-requested: the checks are fixed and changes are still requested. The new ID `…:changes` has **never been seen**, so the row is **unseen again, mood attention**. An improvement re-announces the PR.

**Repro for the Developer:** a PR seen first with more reasons, then with a subset it has never had, alerts again.

**Preferences observation (not a QA write):**

- In run 1, the hash-only check showed the **real** `dev.github-pet.GitHubPet` domain contents changed; its frame keys did not.
- QA launches use in-memory suites. Watching only the plist's mtime with **no QA app running** showed it being rewritten about every 2 minutes (12:13:56, 12:15:57, 12:17:50). Chris's running preview build `c47d8b4` contains PR63, so it persists its seen-items baseline to its own domain after each live poll.
- Run 2 was hash-equal.
- While 15015 runs, the driver's whole-domain hash check for `dev.github-pet.GitHubPet` can report a change that isn't QA's. Read it together with the protected-app timeline. No preference values were read, and nothing was restored.
