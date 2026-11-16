# PR51 3f89207 affected-flow functional QA

**Functional verdict: scoped PASS.** All four affected flows pass as non-regression checks at `3f8920760acb3c6acf31b02d307cd4e4182d310e`, and the source review (below) passes.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task D(2) from PM t61, 2026-11-16. This covers the affected flows only. It is not release, install or live-account acceptance.

## Head and source

- **3f89207 is test-only** over 7e52cac (`Tests/GitHubPetCoreTests/BoundedCommandTests.swift`, +3/-2). The taskless `budget.check()` now runs on a dedicated `DispatchQueue(label:)` instead of `DispatchQueue.global()`, and the group wait goes from 2 s to 20 s. The assertions are unchanged, including `.cancelled` and "not reported as a deadline". Because the latch is checked before the deadline, a late run still reports `.cancelled`. This fixes the CI 43879864048 starvation flake. No production change.
- **Production source** is identical to 7e52cac, which QA reviewed with no findings above INFO; see `docs/qa/pr51-7e52cac/REPORT.md`.

## Artifact

| Item | Value |
|---|---|
| CI | 43881621725, completed SUCCESS on headSha 3f89207… (`ci.json`) |
| Artifact | `GitHubPet-app` from that run, downloaded with gh (`artifact-metadata.json`) |
| ZIP SHA256 | `d9c0a972c644cb040cff166c3d25159063ae567a615aa1695762424c07aff1b4` (matches the sidecar) |
| Binary SHA256 | `56db1572e80643deebc360875d40c9c8a22e6f189b60f7a142e50919d455be56` |
| Info.plist | `GitHubPetSourceRevision` = 3f8920760acb3c6acf31b02d307cd4e4182d310e (**verified equal**), build 123 |
| Signature | `codesign --verify --deep --strict` PASS |

## Method and safety

- **Driver:** `scripts/qa/pr51-3f89207-affected.py` → existing `scripts/qa/scope-artifact-functional.py`. No CI wait, retries, source build, signals or force-quit.
- **Launches:** 4 sequential launches of the artifact binary only (PIDs 89717, 89730, 89743, 89788). Every launch passed `--simulate-monitoring-scope` first, then `--qa-scenario` and a fresh `--qa-output`.
- **Isolation:** each run used its own ephemeral defaults domain. There was no GUI/CUA binding and no normal launch.
- **gh tripwire:** never invoked (`ghInvoked: false`, no `invocations` file).
- **Preferences:** the hash-only snapshots before and after are equal (`preferencesEqual: true`).
- **Protected app:** PID 31897 (`b0127f0`) was present before and after with its original start time, Nov 14 12:44:32. Afterwards no other GitHubPet process was running.
- **Logs:** each run's stderr has only the mascot-pack load line. The roundtrip quit cleanup shows 0 domain keys, no plist, 0 held and 0 late replies.

## Functional judgement

Helper exit 0 only shows that a run completed. I compared every step record field by field (excluding only the per-run `defaultsDomain`) against earlier QA runs that I had already judged PASS. I also looked at three PNGs myself.

| Flow | Steps | Evidence | Verdict |
|---|---|---|---|
| `settings-discovery-partial` | 5 | All 5 steps and runner.json are **identical** to e57d1f3. Organisations show "100 found (incomplete)" with "GitHub reported an error". Repositories show 3, end of list. Typed Add still works, and the active scope and Inbox are unchanged. PNG `step-04…scope-section` matches. | PASS |
| `settings-discovery-identity-mismatch` | 8 | All 8 identical to e57d1f3. Mismatch discards hints with "account changed" copy. Running Find again gives 3+3. Switching to account B clears the hints and shows B's own scope. | PASS |
| custom `discovery-roundtrips` (A→B→A, CLI→Fixtures→CLI; scenario file identical to e57) | 10 | All 10 identical to e57d1f3. Hints reset after every switch. Find works after each roundtrip, Fixtures is clearly labelled Demo and disables Find, and quit cleanup is clean. PNG `step-09…scope-section` matches. | PASS |
| `settings-validation-failure-keeps-active` (includes the `demo-renamed` target rename) | 17 | All 17 steps are **identical** to the accf14b baseline. Details below. | PASS |

Details of the validation flow:

- **Rejected entries:** a denied org or unknown repo gives "2 entries could not be verified", with per-row errors.
- **Target rename:** `demo-renamed/pet` gives "GitHub reports a different current name. Enter the current name." and the active scope is unchanged.
- **Network failure:** "Could not reach GitHub. Nothing was applied."
- **Held Apply:** shows "Checking access…" and Apply is disabled. Switching to account B (gen 3) discards the draft with a clear message.
- **Late reply:** the held validation is delivered late and is discarded (received 4/4, discarded 1). It now passes through the cancellation latch, and its effect is identical to before.
- **Return to A:** account A's original scope is back (gen 5), and the active scope was never changed. PNG `step-16…scope-section` matches.

Fail-closed state held throughout: no partial or error result looked empty or complete, no stale hints or commits, and no active-scope corruption.

**Known C1 (non-blocking, unchanged):** after an account or source change, the previous "N found" status line can still show under "Suggestions not loaded" (roundtrip step 09 PNG).

## Limits

- **Not reproduced through the app:** the new cancellation bridge (an in-flight cancelled gh child, no later pages), viewer-login rename between discovery pages, numeric `hasNextPage`, and the LOW-4 reason text. The offline simulation has no hook for in-flight cancellation of discovery, rename-with-same-ID, numeric pageInfo or a malformed connection. The Developer's before/after regressions cover these; QA reviewed that evidence under 7e52cac.
- **Not exercised:** the held simulated validation in this flow is released only after the account switch, so it shows only that the late reply is still discarded; it does not show early teardown.
- **Not re-run:** the other accf14b flows and the native-frame evidence were reused. Production source is unchanged since 7e52cac, and the 7e52cac delta is limited to the cancellation, identity and parser paths.

## Evidence committed

- **Top level:** `ci.json`, `artifact-metadata.json`, `provenance.json`, `checkpoint.json`, `discovery-roundtrips.json`.
- **functional/:** `provenance.json`, `completion.json`, `progress.json`, `preferences-{before,after}.json`.
- **Per run:** `functional/<run>/launch.json` and `functional/<run>/records/*.json`, plus three scope-section PNGs.
- **Kept local only:** the ZIP, the extracted app, the render-check output and the other PNGs.
