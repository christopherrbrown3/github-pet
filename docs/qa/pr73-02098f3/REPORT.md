# PR73 02098f3 QA: hidden-only inbox plus workflow-failure rows (#10 follow-up)

**Source review PASS.** No functional run (Actions can't be simulated).

QA: Claude Opus 5.5 (`claude-opus-5-5`), task AC from PM t61, 2026-11-17.

- **Head and CI:** `02098f3476d20fd8db833d1d65fed9f805c5f841` contains main cd2da4f. CI 44148874373 completed SUCCESS on the exact head. Only `AppModel.swift` (`displayedState`) and a new test file change.
- **`displayedState`:**
  - **Empty inbox:** unchanged. It shows Partial while `actionsQuality` is set, Ready with failure rows, and Empty otherwise.
  - **Hidden-only inbox:** **unchanged without failure rows**. With failure rows it shows **Ready**, or **Partial** while Actions are incomplete. Ready gives a badge of `items.count` (failure rows included) plus the hidden-matches note (`hiddenResultsNote` requires `.ready`); Partial gives "N+".
  - **Every other state:** passes through unchanged.
  - **Never All clear:** `.empty` is returned only when the inbox is empty, Actions are complete or off, and there are no failure rows. ✔
- **Fail-before** (`actions-badge-evidence/before.txt`, on cd2da4f): `hiddenOnlyInboxWithFailureRowsCountsThem` fails with **3 issues**: the state wasn't `.ready` and the badge wasn't "1", the status started "No visible items", and there was no hidden note. After the fix: 8/8. The gate on the exact head (`actions-badge-gate`, HEAD 02098f3) passes 557 tests in 91 suites, the descriptor test passes in isolation, and no new preference files appeared.
- **Relaunch test:** `relaunchSeedsExistingWorkflowFailuresSilently` uses a second `AppModel` on the same in-memory suite. A pre-quit failure is present with `unseenCount == 0`, and a later failure announces once. This locks in the existing behaviour, so it passes before as well, as expected.
- **INFO:** while Actions are incomplete (Partial), the hidden-matches note isn't shown, because `hiddenResultsNote` is shown only in `.ready`. The inbox's hidden count is still valid then. That's minor, and it reappears once Actions recover.
