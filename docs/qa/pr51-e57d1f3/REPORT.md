# PR51 e57d1f3 affected-flow functional QA

**Scoped PASS (non-regression) for three affected discovery workflows at e57d1f3a8516d3bcdec6d8fb9edf821769052932.** These runs do not exercise the two new code paths directly (see Limits). The three open review defects (offPool cancellation, login rename, numeric `hasNextPage`) are not covered here. PR51 merge stays on HOLD for those.

QA: Claude Opus 5.5 (`claude-opus-5-5`), dispatched by PM t61. This report judges existing evidence from helper t60. Nothing was rerun. No unit tests or core-linked harnesses were written.

## Artifact and provenance

| Item | Value |
|---|---|
| PR head | `e57d1f3a8516d3bcdec6d8fb9edf821769052932` (delta over accf14b: `7f12ebc` discovery epoch/cancel guard, `e57d1f3` failed-exit makes categories partial) |
| CI | run 43808396247, `build-and-test` SUCCESS (`ci.json`) |
| Artifact | 14200072032 `GitHubPet-app`, downloaded with gh (`artifact-metadata.json`) |
| ZIP SHA256 | `89dfc448b8783db9c57b1e06dbadc9afbe3d9ec2dc337e7da5e51252732ec09d`. I recomputed it and it matches the sidecar |
| Binary SHA256 | `833de802b4080cfd66061914f34ac065e9bb0756ed26b2a1a05eeb305e3df2b0`. I recomputed it |
| Info.plist | `GitHubPetSourceRevision` = e57d1f3a…, build 118, 0.1.0. Strict signature PASS (`provenance.json`) |

The ZIP and extracted app stay local and untracked because of their size.

## Method and safety

Each scenario ran once, in order, from the extracted artifact binary. Every launch passed `--simulate-monitoring-scope` first, plus `--qa-scenario` and a fresh `--qa-output` (see `functional/*/launch.json`, PIDs 78888, 78909, 78931). Each run used an ephemeral defaults domain `dev.github-pet.scope-simulation.<pid>.<uuid>`. There was no GUI/CUA binding and no normal launch.

- **gh tripwire:** `functional/tripwire/gh` appends to `invocations` and exits 1. The `invocations` file does not exist, so gh was never invoked.
- **Preferences:** `preferences-before.json` and `preferences-after.json` are byte-identical.
- **Cleanup:** the roundtrip quit record shows 0 domain keys after cleanup, no plist on disk, 0 held and 0 late replies.
- **Protected app:** PID 31897 (`b0127f0`) is still running with its original start time, Sat Nov 14 12:44:32 2026.
- **Helper output:** every run's stderr contains only the mascot-pack load line.
- **Judgement basis:** helper exit 0 / `completed: true` only shows that the harness finished. I judged every step JSON record (23 in total). I also looked at these four PNGs myself:
  - `settings-discovery-partial/records/step-04-settings-partial-scope-section.png`
  - `settings-discovery-identity-mismatch/records/step-07-settings-account-b-scope-section.png`
  - `discovery-roundtrips/records/step-09-settings-cli-after-roundtrip-scope-section.png`
  - `discovery-roundtrips/records/step-06-switch-fixtures-clears-hints-inbox.png`

## Functional judgement

| Flow | Observed (step records / PNG) | Verdict |
|---|---|---|
| **settings-discovery-partial** (built-in, 5 steps) | Before Find, status reads "Suggestions not loaded" with no hints. After an explicit Find, 2 pages are fetched. Organisations show "100 found (incomplete)". Repositories show "3 found (end of this list)", which is correct because the repos finished on page 1, before the page-2 error. The copy includes "GitHub reported an error" and "you can type any owner/name". The partial result is never shown as empty or complete. Typed Add `demo-z` works and enables Apply. Active scope (Selected A, gen 1) and Inbox (Up to date, 1 row, 0 unseen) are unchanged. The PNG matches the records. Output is identical to the accf14b run. | PASS |
| **settings-discovery-identity-mismatch** (built-in, 8 steps) | Complete Find gives 3+3 hints. In mismatch mode, Find runs 2 pages (viewer changes A→B on page 2). It discards all hints with "Suggestions discarded: the GitHub CLI account changed. Typed entries can still be added." and the earlier A hints are cleared rather than kept. Returning to complete mode and running Find again gives 3+3. Switching the account to B (gen 3) clears hints, the draft shows B's own repo `demo-b/pet`, and Settings shows `demo-b_sim`. Active scope and Inbox stay consistent at every step. | PASS (with C1 below) |
| **discovery-roundtrips** (custom A→B→A, then CLI→Fixtures→CLI, 10 steps, `discovery-roundtrips.json`) | A Find gives 3+3. Switching to B clears hints (gen 3). Returning to A gives "Suggestions not loaded" with 0 hints (gen 5), so A's hints are not resurrected. A Find after the roundtrip works (2 launched / 2 received / 0 discarded). Switching to Fixtures gives Demo scope "Everything", Find is disabled with "Suggestions need the GitHub CLI source", the Inbox is clearly labelled DEMO / Simulated with 3 demo rows, and hints are cleared. Returning to CLI gives "not loaded" again (gen 7), and Find works (3/3/0). Quit cleanup is clean. | PASS |

The checks on the partial and denied paths are fail-closed: neither is ever shown as empty or complete. No stale hints leaked across an account or source change. I saw no stale commit and no active-scope corruption.

### Known non-blocking copy observation C1 (still present)

This was first recorded in `docs/qa/pr51-accf14b/REPORT.md`, and it still reproduces at e57. After an account or source change, the status line correctly reads "Suggestions not loaded", but the previous announcement ("Suggestions: organizations 3 found … repositories 3 found …") is still shown underneath it.

- **Mismatch run, step 07:** visible in the account-B PNG.
- **Roundtrip run, step 09:** the same text appears twice.

No hints actually leak: the pickers are empty and disabled. This is stale status copy only, and PM can track it separately.

## Limits (not covered; Developer regression responsibility)

- **e57d1f3 nonzero-exit path is not exercised.** The simulated `partial` mode returns `exitCode: 0` with GraphQL `errors` on page 2, and `denied` returns exit 4 with empty stdout. Neither produces "nonzero exit with a parseable envelope", which is exactly what e57 changed. The partial run is therefore a non-regression check, not positive evidence of the fix.
- **7f12ebc cancelled-in-flight path is not exercised.** The roundtrips are sequential: every discovery finished before the next switch (0 held, 0 discarded). A completion from an old cancelled origin overwriting a replacement during A→B→A or CLI→Fixtures→CLI was not reproduced here.
- **Not covered: the three open review defects.** These are the `ScopeEditor.offPool` work that does not inherit Task cancellation, the `ScopeViewer` equality that includes login (rename between pages), and `hasNextPage as? Bool` bridging JSON 0/1. The simulation cannot inject a rename-with-same-id, a numeric `hasNextPage`, or a held off-pool process. These need Developer negative-before/positive-after regressions.
- **Also out of scope:** live GitHub accounts, install/release, and launches outside simulation. The other 15 accf14b flows and the native-frame evidence were reused and not rerun. The 7f12ebc/e57d1f3 delta touches only `ScopeEditor` discovery and `ScopeDiscovery.run`.

## Evidence in this folder

- **Top level:** `ci.json`, `artifact-metadata.json`, `provenance.json`, `checkpoint.json`, `discovery-roundtrips.json` (custom scenario), `ci-render/report.txt`.
- **functional/:** `provenance.json`, `completion.json`, `progress.json`, `preferences-{before,after}.json`.
- **Per run:** `functional/<run>/launch.json` and `functional/<run>/records/*.json`, plus the four PNGs listed above.
- **Kept local only:** the other PNGs, the app ZIP, the extracted app and the raw logs.
