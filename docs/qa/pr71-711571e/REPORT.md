# PR71 711571e QA: MED-1 fix re-check (#9)

**PASS.** MED-1 is fixed on the exact-head artifact, and dedupe across inclusions holds.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task X from PM t61, 2026-11-17.

- **Head and CI:** `711571e569c495a3c9128056f0604190930ad42b` contains current main d9d69f6. CI 44136481405 completed SUCCESS on the exact head.
- **Merge:** `711571e` (faa1d29 and d9d69f6) equals the automatic merge-tree `6e20e2d…`. There is no source or test change since faa1d29, and the README now carries PR70's Releases wording.
- **Source review:** the 5f0ebf3 delta was reviewed and PASSED earlier (see the PR71 comment and the t61 message).
  - **IDs and keys:** each PR has a stable ID, and its reason keys are stored as digests.
  - **What announces:** only a new ID or a gained, never-seen key.
  - **Inclusions:** overlapping inclusions give one row; disagreement gives Partial.
  - **Tests:** fail-before 3/5, after authored 22/22, gated full suite 533.
  - **LOW:** sharing the tracker's 1024 entries is noted for #60.
- **Artifact:** `GitHubPet-app` 14352638100. ZIP `ed441af1fc53acdfc847e0bfe69c09035d02c7cadb8d4efb40224544c2a0f402` matches the sidecar. The revision is 711571e (build 221), and strict codesign passes.

## Single simulated launch

The launch ran with `--simulate-monitoring-scope` first, existing runner actions only, and an in-memory suite. The 15015 guard held: the protected app was unchanged (same PID, start time and path). gh tripwire 0, and the preferences hashes are equal.

| Step | Observed | Verdict |
|---|---|---|
| authored checks-failing (first sighting) | One row, `authoredPullRequest:…_needs` (stable ID), "Changes requested, Checks failing", unseen, mood attention, waiting 3, badge 2 | PASS |
| mark-seen | unseen 0, mood idle | — |
| changes-requested (checks fixed; this was the old MED-1 repro) | The same row now reads "Changes requested", **unseen stays 0, mood idle**: no re-announce | **PASS (MED-1 fixed)** |
| checks-failing again on the same head | "Changes requested, Checks failing", still seen, idle: regaining a reason on the same head is silent | PASS |
| Apply org `demo-a` + repo `demo-a/pet` | The poll queried `authored0` and `authored1`. Still **one** authored row and waiting **3** (not 6); scope header "1 organization, 1 repository"; Up to date (the inclusions agree) | PASS |

Not exercised here: a gained reason on a new head commit announcing once, and disagreeing inclusions giving Partial. The simulator can't produce either; the Developer's `AuthoredAnnouncementTests` cover them.

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, `authored-fix-recheck.json`, and `functional/{completion,progress,provenance,preferences-*}.json` plus the records.
