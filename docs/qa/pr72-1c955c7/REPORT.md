# PR72 1c955c7 QA re-check: MED-2, Actions independent of the inbox (#10)

**PASS.** MED-2 is fixed. There is one LOW (a badge edge case) and one LOW test gap. No functional run: Actions can't be simulated.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task AB from PM t61, 2026-11-17. No app was launched.

- **Head and CI:** `1c955c7d852db4a093168dc8d92679f28a7ac60c` contains main ca4c801. CI 44145931842 completed SUCCESS on the exact head.
- **Baseline revert:** `EventBaseline.swift` is identical to main, so the last round's `BaselineKey` change is fully reverted.
- **`mergingActions` removed.**

## Delta review

- **Inbox untouched:** `poll` returns `RepositoryReply(inbox:, actions:)`, and the inbox `ScopedPollResult` is exactly the scoped client's. `scopeSession.receive`, `InboxEngine` and the persisted baseline see **only** the inbox, so its completeness, comparability, hidden count and `waitingOnOthers` (PR71) are unchanged. ✔ No PR71 regression.
- **Actions separately:** `applyActions` runs after the inbox `apply`, on `.apply` only, so the generation and identity guards still apply.
  - **Own engine and key:** Actions have their own `actionsEngine` and an `actionsCoverageKey` (viewer ID plus the sorted watched qualifiers). A key change calls `resetActions()`, which removes **only** the Actions rows' unread markers and resets the Actions engine. Inbox dots are preserved, which also fixes the earlier LOW-3.
  - **Alerts:** events come from `actionsEngine.apply(snapshot(complete: result.complete))`, so Actions alerts depend **only on Actions completeness**.
  - **Quality line:** `actionsQuality` uses fixed text with counts only (account changed, rate limit, access denied, N unavailable, result limit, generic, or "weren't checked this time" when the inbox reply wasn't usable).
  - **Last-known rows:** `ActionsLastKnown` keeps its " · last known" rows.
  - **Shared state:** `unseen.reconcile` uses inbox plus Actions items in both paths, so neither engine clears the other's dots. Turning the watch off (`.off`) resets the Actions engine and its rows.
- **Never "All clear":** `displayedState` shows an empty inbox as **Partial** while `actionsQuality` is set, and as **Ready** while failure rows exist; otherwise it is the inbox's own state.
- **Privacy:** Actions rows use the same `PrivacyText` (title and repository hidden), and the quality line has no names. ✔
- **Fail-before** (`pr72-med2-evidence/before-probe.txt`): on e6add42, with an unreadable watched repository, a new review request didn't announce (`unseenCount` 0 instead of 1). After the fix: 22/22 targeted, including `anUnreadableWatchedRepositoryNeverSilencesTheInbox`, `actionsRecoverIndependently` and `anEmptyInboxWithAnActionsProblemIsNotAllClear`. The gate on the exact head (`pr72-gate4-evidence`, HEAD 1c955c7) passes 555 tests in 90 suites, the descriptor test passes in isolation, and no new preference files appeared.

## Relaunch (PM question)

The Actions seen-state is **not persisted**, so after a relaunch `actionsEngine` starts empty with no tracker. Its first **complete** result goes through `!tracker.baselineEstablished && complete` and is seeded **silently** (no events, no burst). If that first result is Partial, IDs are recorded without events. Confirmed from source.

**Acceptable for beta:**

- It never re-announces existing failures after a relaunch.
- A failure **you** triggered still shows the urgent mascot through its `critical` severity, so the important signal isn't lost.
- The cost, that failures appearing while the app was quit aren't announced, is documented in the README Limits ("Workflow failures aren't remembered across a relaunch…").

**LOW-2:** there is no explicit test for relaunch-seeds-silently. Consider adding one, two `AppModel`s on the same in-memory suite, to lock it in.

## Finding

- **LOW-1: the badge can say "0" next to visible failure rows.**
  - **When:** the inbox is `.hiddenOnly(n)` (no visible inbox rows, but hidden matches) while Actions failure rows exist. `displayedState` only overrides `.empty`, so the state stays hidden-only.
  - **Effect:** the status reads "No visible items · n matches hidden from your account", and `MascotPolicy.badge(.hiddenOnly)` returns **"0"**, while the list shows workflow-failure rows. Mood is still correct (critical gives urgent).
  - **Suggestion:** treat `.hiddenOnly` like `.empty` when `actionsEngine.items` is non-empty (Ready plus the hidden-results note), or Partial when `actionsQuality` is set.
