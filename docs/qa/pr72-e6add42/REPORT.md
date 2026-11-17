# PR72 e6add42 QA re-check: Actions failures slice 1 (#10)

**Delta review PASS for MED-1, LOW-1 and LOW-2, with one new MED-2 to decide, plus two LOWs.** No functional run: Actions can't be simulated.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task AA from PM t61, 2026-11-17. No app was launched.

- **Head and CI:** `e6add42f20ba7522b20e1efa53d73369f1182d54` contains main ca4c801. CI 44142550510 completed SUCCESS on the exact head. The delta is one commit on d1345e8 (5 files).

## Fixes

- **MED-1, silent seed:** `BaselineKey` appends `a<coverageVersion>:<sorted watched repository qualifiers>` **only when the list is non-empty**, so existing keys (and saved records) are unchanged with the watch off. Turning the watch on, or changing the watched set, changes the key. `AppModel.apply` then calls `resetRepositories()`, loads the new key (nothing saved, so a fresh tracker), and the first complete snapshot **seeds silently**. Tests `enablingTheWatchSeedsExistingFailuresSilentlyThenAnnouncesNewOnesOnce` and `addingAWatchedRepositorySeedsItsExistingFailuresSilently` confirm that existing failures show without unseen and a later failure announces once.
- **LOW-1, last-known rows:** `ActionsLastKnown` (locked) keeps the last readable failures per watched repository. If a repository can't be read in a cycle (`targetUnavailable`, `malformedTarget`, `malformedSource`, or no viewer or source at all), its previous rows return with the **same ID** and " · last known" added to the title. The cycle's issues keep the snapshot **Partial**, and there's no re-announce. It resets when the account or watched set changes and on `identityMismatch`.
- **LOW-2, fail closed:** status must be in `knownStatuses` and the conclusion in `knownConclusions` (or null when not COMPLETED). A COMPLETED suite without a conclusion, an unknown value, or a non-string conclusion is a malformed row, so the result is Partial.
- **Evidence:**
  - Behavioural fail-before for LOW-2 only (`before-low2-probe.txt`: an unknown conclusion was skipped). MED-1 and LOW-1 show only a **compile** failure before, because the tests use the new `actionsRepositories:` API. There is no behavioural before/after showing the enable burst or the dropped rows.
  - After: 21/21 targeted. The gate on the exact head (`pr72-gate3-evidence`, HEAD e6add42) passes 554 tests in 90 suites, the descriptor test passes in isolation, and no new preference files appeared.

## Judging the whole-slot reset (PM question)

A key change is a full `resetRepositories()`: the engine is reset (tracker and items), `unseen.removeAll()`, repository clips are cleared, and `detailsRevealed` is set to false. All of this happens within the same `apply`, so no Loading state is visible.

- **No re-announce of inbox items:** the reset is followed by a silent seed of everything currently present, including review requests, assigned issues and authored PRs. ✔
- **Seen state that is lost:**
  - **Unread dots:** existing unread (unseen) dots on review requests, assigned issues and authored PRs are cleared, and a playing gesture stops. The test even allows `unseenCount <= before`.
  - **Missed announcement window:** an inbox item that **first appears in the same poll** as the key change is absorbed silently, about one refresh interval (≤ 120 s, triggered immediately by `requestRefresh`). If that poll is Partial, the absorption continues until the first complete poll.
- **Verdict:** acceptable for beta. The toggle and repo-set edits are rare, deliberate user actions, and this is the same behaviour as an existing scope change, which also re-keys. Worth a Limits or Settings line, and a later refinement: seed only the Actions IDs, without a whole-slot reset.

## New findings

- **MED-2 (design consequence, needs a decision): a permanently unreadable watched repository silences every inbox alert.**
  - **Mechanism:** `mergingActions` adds every Actions issue to the inbox snapshot's issues, so the snapshot isn't complete. `InboxEngine` announces only when `complete && previousWasComparable`, and Partial snapshots are never comparable.
  - **Effect:** one watched repository that can never be read (SAML not authorized, access removed, or an over-cap commit with more than 20 suites) keeps every poll Partial **indefinitely**. **No new review request, assigned issue or authored PR ever announces**, and the inbox shows "Partial data" permanently.
  - **Why it matters:** an *optional* add-on failure disables the core alerts. It's fail-closed, but it's a big hidden cost of turning the watch on.
  - **Suggestion:** treat Actions problems as an Actions-only quality line, with workflow rows last-known and inbox comparability kept when the inbox searches themselves are complete. Or make comparability per category. At minimum, state it in Settings and Limits.
- **LOW-3: unread dots are cleared on a re-key** (above). Consider preserving `unseen` for IDs that are still present across an Actions-only re-key.
- **LOW-4: no behavioural fail-before for MED-1 and LOW-1.** A quick probe on d1345e8 would document the bug: enable the watch with an existing failure and expect an unseen increase.

## Functional

Not possible without new hooks. Simulated launches get no Actions client unless a test injects one, and the renderer doesn't capture the Settings section. Live coverage is in `docs/qa/beta-smoke-checklist.md` §16, which also catches MED-2 at its step 5.
