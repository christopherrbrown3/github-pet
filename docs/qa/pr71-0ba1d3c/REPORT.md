# PR71 0ba1d3c QA: authored-PR attention (#9)

**Source review PASS with one MED design point.** The functional run is **pending a PM decision**. The driver guard refused before launching because the protected saved app PID 31897 is no longer running, and a different GitHubPet process is (see below).

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

## Functional: pending

The QA runner's existing `authored` action (modes `changes-requested`, `checks-failing`, `churn` and `off`) can show:

- a needs-action row
- the waiting line
- churn producing no event
- a new failing head producing one event
- **the MED-1 re-announce**, by going back to `changes-requested`
- privacy turned off

All of it uses existing actions only. The scenario and helper are ready (`authored-attention.json`, `scripts/qa/pr71-0ba1d3c-authored.py`).

**Not run:** the driver guard ("only the protected PID 31897 may be running") refused before launching. **PID 31897 is no longer running.** Instead, PID 15015, `/Users/chris/github-pet-builds/main-0f73723-beta-preview/GitHubPet.app` (no arguments, parent launchd, started Nov 16 14:41), is running. That looks like a normal launch by Chris, and QA did not cause it: QA's last app launch (the PR65 render) recorded 31897 still present afterwards, and every task since has been read-only. QA needs PM to confirm the new protected process before running anything.
