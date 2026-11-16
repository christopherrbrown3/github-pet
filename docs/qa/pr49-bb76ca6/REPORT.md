# PR49 functional QA via the scenario runner

Head **`bb76ca644d2ac9af4b0be86c47efc88cf6bc3865`** (CI 43799637991 SUCCESS). The release app was built in a fresh detached worktree `qa-verify-bb76ca6`. The Info.plist revision equals the head, and the binary sha256 is `6a842bb4…53d3d`.

QA: Claude QA t4x (claude-opus-5-5).

**Verdict: conditional PASS. All spec behaviours were observed as required, except one finding that PM/Developer must decide on (F1). The runner itself is trustworthy, with one minor input-validation gap (F2).**

## Method

`scripts/qa/scope-scenarios.sh` ran 8 built-in scenarios and 13 adversarial custom scenarios (`docs/qa/pr49-plan/scenarios/*.json`). They ran one app at a time, each into a fresh empty private directory under the QA scratch area. Each launch had:
- a logging fake `gh`, both first on PATH and as `GITHUB_PET_GH_PATH`;
- child-process and `lsof -i` socket polling every 250 ms;
- before/after snapshots of preference domains, plist files and the real-preferences hash;
- a check that the saved b0127f0 process was untouched.

`scripts/qa/pr49-runner-trust.sh` covered R1–R3 and R5. QA judged every step record against #30 by hand (`step-digest.txt`; raw records under `<scenario>/records/`) and viewed PNGs to check R4 agreement (`viewed-png/`).

## Isolation (all 21 runs, 167 mechanical checks)

- The fake `gh` never ran.
- No child processes and no sockets were observed.
- No preference domain or plist was left behind, and no existing one was removed.
- The real `dev.github-pet.GitHubPet` hash was unchanged.
- The saved app pid 31897 was untouched.
- Every run exited 0 by itself.
- After `quit` with held replies (demo-isolation, a13): `domainKeysAfterCleanup` was 0, `plistOnDisk` false, and late replies were counted as discarded.

The only mechanical flag was privacy-summary step 03 `show-details`: names are visible because Show details is the user's explicit, temporary reveal. Hide details restores the generic rows. This is not a defect.

## Spec behaviour, judged from records and PNGs

| #30 behaviour | Evidence | Result |
|---|---|---|
| Restore before display | Launch: Selected `demo-a`, expected A, 1 row, silent. Unknown-viewer reload: Everything (expected none) → bound Selected (expected A). `demo-outside/pet` is never in any recorded state. Known reload: Selected directly. | PASS* |
| A→B→A | B restores explicit `demo-b/pet`, A restores organization `demo-a`. 1 row each, unseen 0, no clip. Same result after a reload with an unknown viewer that turns out to be B (a09). | PASS |
| Stale reply after Apply | Apply Everything + inject gives 3 rows / 1 unseen / repository clip. The held Selected reply is discarded (count 1) and changes no rows or attention. Unchanged Refresh does not replay. A01: two held replies delivered newest→oldest after Everything→Selected are both discarded and the final state is Selected. A02/A03: an A reply held across A→B (and A→B→A) is discarded and never shown. | PASS |
| Corrupt saved Selected | Status "Saved monitoring scope is invalid; monitoring is paused and has not broadened", header "configuration error", badge `?`, "No data available yet" (not verified-empty), and no broadened rows. Refresh keeps the error. Repair restores 1-row Selected silently. Corrupt A does not contaminate healthy B (a04). The incident stays visible beside the error (a08). | PASS, see **F1** |
| Partial → recovery silent, new once | Partial quality text, badge `1+`/`2+`, and the row injected while partial gets no unseen or gesture. Recovery is silent. The next inject gives exactly 1 unseen + clip, and Refresh does not replay it. A Scope Apply in the middle of partial (a05) behaves the same. | PASS |
| Incidents preserved | Major incident: service clip 12:00:00–12:00:02, burst 12:00:00, marker major, 1 unseen incident. Apply Everything and Apply Selected leave all of these unchanged, with no status refetch. The clip ends naturally while marker, burst and unseen remain. Mascot PNG: urgent with a red badge. | PASS |
| Privacy summary | The header shows only mode and counts, never names. Plurals are correct: "1 organization, 0 repositories" and "0 organizations, 1 repository". Rows are generic while privacy is on (PNG). | PASS |
| Demo isolation | Fixtures shows "Demo scope · Everything" with example rows. A held simulated-gh reply delivered in Fixtures is discarded, and Apply is ignored. Returning to GitHub CLI restores Selected A silently. a11 repeats this twice. | PASS |
| Held reply past its limit | After `wait-real` 25 s: "Error: Monitoring scope could not be verified" with "Scope request time limit reached; results are unverified", badge `?` and "Showing last known items" (PNG), never empty. The next Refresh recovers silently. | PASS |
| Repeated Apply (a06), Refresh while a reply is held (a07) | One request per Apply with no request storm or alert. Refreshes while held are coalesced. Exactly one alert once the reply is delivered. | PASS |

\*The runner records state only at settle points, so states *within* the unknown-viewer bootstrap are not captured. The request log and every recorded state show no outside row.

## Findings

- **F1 (decision needed, medium): a corrupt saved selection still sends unrestricted Everything queries.** In `corrupt-saved-selected`, the reload and *every* later Refresh issue an `Everything` request bound to the known account A (requests 2 and 3, generation 2). Active scope stays `null` and no rows display, so nothing broadens visibly. But the UI says "monitoring is paused", while in real `gh` mode each poll would still run a full-account query and drop the result. In a04, switching to corrupt A from B makes no Everything request. Expected: the paused/corrupt state makes no repository query once identity is known, or the copy should not claim "paused". Evidence: `corrupt-saved-selected/records/step-0{1,2}-*.json` (`scopeSimulation.requests`).
- **F2 (minor, runner only):** a boolean step key accepts a JSON number: `{"action":"partial","on":1}` runs as `true` with exit 0 instead of being refused with exit 2. The number check already rejects booleans; the boolean check does not reject numbers. It does not affect product behaviour.
- **Simulator note (not a defect):** `repair` while on account B also switches the simulated account back to A (a04 step 06).

## Runner trust (R1–R5)

- **R1:** `--qa-scenario` without the simulation flag, with `--render-snapshots`, or `--qa-output` without a scenario all exit 2 and write nothing.
- **R2:** 10 of 11 invalid scenarios (malformed, unknown action/key/name, bad label, quit not last, hold 9, wait 61, 100 steps, boolean as number) exit 2 and write nothing. The exception is F2.
- **R3:**
  - Refused: a directory with a foreign file, a marker directory with a hard-linked step file, a symlinked `runner.json`, a regular-file path, `$HOME`, `/System/…` and the app bundle. The victim and foreign files were unchanged.
  - A symlinked ancestor that already exists is resolved once, and output lands only in the real directory.
  - A reused runner directory has its old step files replaced. A relative path resolves under the working directory.
- **R4:** the viewed PNGs agree with their JSON (row counts, unseen dot, badge, status/quality text, last-known, mascot state).
- **R5:** two `stale-reply-after-apply` runs give identical step records apart from `defaultsDomain`.

## Limits

- No real pointer clicks, menu-bar interaction, VoiceOver, live motion/animation timing, physical Intel or real `gh` authentication.
- PNGs are offscreen renders drawn by the app itself.
- Settle-point recording only (see *).
- Identity churn twice in one cycle (an explicit failure) is not expressible with runner steps. That case is covered only by the Developer's unit tests, not functionally.
