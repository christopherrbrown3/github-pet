# PR59 9e401ba QA: #35 hidden results

**Source review PASS and scoped functional PASS** at `9e401baded33611f2fdbcfbb238093c9d38d7207`.

- **Findings:** two new LOW items: the per-repo overlap check and the quality copy. They are non-blocking.
- **Still open:** QA's earlier legacy LOW-2 (`hasNextPage` not queried) was not assigned to the Developer and is unchanged.
- **Scope:** first functional QA for PR59, affected #35 flows only. This is not release, install or live-account acceptance.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task F from PM t61, 2026-11-16.

## 1. Source and diff review (d813f10..9e401ba)

**Merge 138fb1a** has parents d813f10 and main b152656. `git merge-tree --write-tree d813f10 b152656` produces `eaaf04880ffa3c6aa1919443ab57009f3292793e`, which is identical to the tree of 138fb1a. So it was a clean automatic merge, adding nothing beyond PR59 plus main. PR59 now contains PR51's final commits.

**c1fec60 MED-1** (`ScopedGitHub.swift` around lines 214-242):

- **Change:** for each verified org owner, it builds `organizationHidden[kind][owner]` (taking the maximum per alias). A repo target whose verified owner has an org target in the same category is "covered". If a covered repo's hidden count is greater than its org's, the alias is marked `.capped`, which makes the result Partial. Otherwise the covered repo's hidden count is excluded. In the non-clean branch, an alias is no longer listed as capped twice.
- **Verdict:** correct. The defect QA reported, where the result became All clear with zero visible rows, can no longer happen: the org hidden count must be at least as large as each covered repo's, or the result is Partial.
- **Developer evidence** (`/Users/chris/github-pet-builds/pr59-9e401ba-developer-evidence`, base HEAD 138fb1a):
  - Before the fix, `coveredRepositoryHiddenAboveItsOrganizationIsPartialNeverAllClear` fails with `engine.state == .empty`, the exact All-clear defect, as well as `.hiddenOnly(2)` and no `.capped` alias.
  - After the fix: 67 tests in 11 suites pass.
- **LOW-A (new):** the check compares each covered repo with its org, not the **sum** of covered repos with the org.
  - Two covered repos with hidden counts 2 and 2 under an org with hidden 3 is still contradictory, because distinct repos have disjoint matches. Today that result is complete with hidden 3, a quiet under-count.
  - It can never be All clear, because the org count is at least 1.
  - Under "any quality uncertainty → Partial", compare the per-owner sum instead.

**9e401ba LOW-3** (`GitHubCLI.swift`):

- **Change:** a legacy response is now clean only if `total <= Int32.max`, and hidden counts are added only when the response is clean. The sum of at most two pages therefore cannot overflow.
- **Verdict:** correct.
- **Developer evidence** (base c1fec60): before the fix, `unboundedIssueCountsArePartialAndNeverOverflowTheHiddenSum` traps (signal 5); after it passes (33 tests).

**Full suite and CI:**

- **Full suite:** the CI-style run passes 425 tests in 67 suites. In a plain in-process run, the existing `/dev/fd` test `descendantHoldingThePipeDoesNotLeakReadsOrDescriptors` failed once (8 ≤ 7). It is older than PR59, the CI workflow runs it in its own isolated process, and it passes alone. The Developer disclosed this; QA records it as INFO.
- **CI:** 43885610761 completed SUCCESS on exactly 9e401ba.

**Checked against issue #35 decision 6903109382:**

| Rule | Status |
|---|---|
| Full cap → Partial | Holds |
| Hidden-only → never all-clear | Holds (badge 0, its own state text, no warning, no mood change) |
| Any uncertainty → Partial | Holds, apart from LOW-A |
| Counts only, no names | Holds |

## 2. Functional (actual CI artifact)

| Item | Value |
|---|---|
| CI | 43885610761, completed SUCCESS on headSha 9e401ba… (`ci.json`) |
| ZIP SHA256 | `17001cfd28cec40fb1014955ea64d3ff22403ad63c16bcbce8e2bb8e5021ef54` (matches the sidecar) |
| Binary SHA256 | `57b6f52de9aad1e3460c75caf525d4513cbe9062c396013bead69eb9fce2128c` |
| Info.plist | `GitHubPetSourceRevision` = 9e401ba… (**verified equal**), build 133. Strict codesign PASS. |

**Method and safety:**

- **Driver:** `scripts/qa/pr59-9e401ba-affected.py` → existing `scope-artifact-functional.py`.
- **Launches:** 2 sequential artifact-only launches. Each passed `--simulate-monitoring-scope` first, used an ephemeral defaults domain, and used only existing actions; no new hooks.
- **gh tripwire:** not invoked.
- **Preferences:** the hash-only snapshots before and after are equal.
- **Protected app:** PID 31897 kept its original start time, Nov 14 12:44:32. No QA app was left running.
- **Logs:** each run's stderr has only the mascot-pack line. Quit cleanup shows 0 keys, no plist and 0 held.

**Judgement basis:** helper exit 0 only shows that a run completed. I judged all 46 step JSON records and viewed these five PNGs myself:

- hidden-only Inbox
- hidden-only mascot
- visible-plus-hidden Inbox
- `capped` (`hasNextPage`) Inbox
- full-page cap Inbox

| Case | Flow / step | Observed | Verdict |
|---|---|---|---|
| Visible + hidden | hidden-results 01, 04, 06 | "Up to date", badge 1, 1 row, informational note with eye.slash icon: "3 matching items aren't visible to your account". No warning, mood idle, unseen 0. | PASS |
| Hidden-only (0 visible) | hidden-results 02 | Status and empty text both say "No visible items · 3 matches hidden from your account"; badge **"0"** (not the no-badge all-clear); mood idle, no alert; no "All clear" anywhere. The mascot PNG shows the blue "0" badge. | PASS |
| Cap via `hasNextPage` | hidden-results 03 | "Partial data", badge "1+", warning "Scope result limit reached; counts are incomplete.", hidden 0, no note. | PASS |
| **Full-page cap (n = 30, count > n, no next page)** | custom fill-28 → fill-29 | At 29 visible nodes plus 3 hidden: Up to date, badge 29, note. At **exactly 30 nodes** with count 33 and `hasNextPage` false: **Partial data, badge "30+"**, limit warning, hidden 0. With all visible (count 30): Up to date, badge 30. | PASS |
| Hidden plus error | hidden-results 05, 06 | Partial and hidden zeroed. Recovery brings back "Up to date" with the note. | PASS, see LOW-B |
| New row once | hidden-results 07, 08, 09 | 1 unseen with one repository clip. Hidden matches never drive mood or alert. Privacy off still shows counts only. | PASS |
| **Org/repo overlap (equal counts)** | custom 02-05 | Applied Selected = org `demo-a` + repo `demo-a/pet` (4 aliases). In hidden mode both the org and repo review aliases report +3, and the **total is 3, not 6**. Hidden-only also gives 3, with badge 0. | PASS |
| Overlap contradiction (repo > org) | not simulatable | The simulator adds the same +3 to every review alias. Covered by the Developer's MED-1 regression (fail-before/pass-after). | Developer |
| Legacy client (`GhClient`) | not exercised | The app constructs only `ScopedGhClient`. LOW-3 is covered by the Developer's regression. | Developer |

During the fill sequence, the 30th row arrived in a Partial snapshot, so no new alert fired and recovery stayed silent (unseen stays at 28). This matches the established partial and recovery policy that QA accepted for accf14b.

**LOW-B (copy, existing semantics):** when the page also contains an `errors` member (step 05), the quality line says "Scope result limit reached; counts are incomplete." rather than "Monitoring scope could not be fully verified…". The same simulated error without hidden matches showed the latter at accf14b. The cause is in `ScopedGitHub.swift`: in the non-clean branch, every hidden alias is converted to `.capped`, and `RepositoryScopeSession.qualitySummary` (line 164) ranks capped above the generic message. It is still Partial (fail-closed), and the same thing happened before #35 because count > nodes was always capped. However, the copy names the wrong cause. Suggested fix: rank the generic or error message above capped, or skip the conversion when another issue already makes the response Partial.

## Limits

- Not simulatable without new hooks: the overlap contradiction, a summed multi-repo overlap (LOW-A), the legacy client, and numeric or malformed counts.
- Not covered: live GitHub visibility semantics, native window, VoiceOver, Intel and install.

## Evidence committed

- **Top level:** `ci.json`, `artifact-metadata.json`, `provenance.json`, `checkpoint.json`, `hidden-overlap-fullpage.json`.
- **functional/:** `provenance.json`, `completion.json`, `progress.json`, `preferences-{before,after}.json`.
- **Per run:** `functional/<run>/launch.json` and `functional/<run>/records/*.json`, plus the five PNGs listed above.
- **Kept local only:** the ZIP, the extracted app, the render-check output and the other PNGs.
