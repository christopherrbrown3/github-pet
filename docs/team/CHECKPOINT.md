# Latest checkpoint — 2026-11-15 PR48 merged, #30 slice 2 planning

Sole PM is **t49 product-manager** (Claude Opus 5.5) since explicit HANDOFF_GRANTED from Codex t1r. Specialists report via `hc send t49`. Developer owns unit/logic/regression tests and build CI; QA is functional only.

- PR48 core/transport merged at exact head `52d5124384817b63dc6d3ee2d58dcd4b9491ba45` as **`f997d1d51b9f6a1d93c61f2d76fe56f60305eaee`** (`--match-head-commit`). Gates: CI43740674826 SUCCESS, Copilot5911935714 no open issues, 0 unresolved threads, independent functional QA PASS for the offline core/transport scope (comment6902058672, QA commit eef2d88). Live-auth/UI/install checks were not claimed. App behavior is unchanged (Everything).
- #30 stays In Progress. Developer t1s has been dispatched slice 2 (native Settings scope UI, AppModel/engine adoption, discovery) in new worktree developer-scope-ui on branch feat/30-scope-ui from f997d1d, **plan first**; production edits wait for PM approval. QA will then functionally test the built app through fixture/test hooks.
- **Specialist swap (Chris request):** Codex Developer t1s and QA t1t gave final state and stopped writing. Claude Opus 5.5 **claude-developer t4w** (developer-scope-ui, PR49 at 262ee9b, CI43771499729 pending) and **claude-qa t4x** (qa-engineer, functional only) launched. PR49 history: CI failures root-caused (runner-slow deadline -> silent baseline, not motion; isolated fd-test guard wording); Copilot findings fixed except corrupt-selection Settings wording, now assigned.
- Saved main b0127f0 app/ZIP remain immutable. No release/tag/auto-merge/Homebrew.

---

# Latest checkpoint — 2026-11-15 Claude PM handoff

Chris requests new Claude PM after allowance reset, authorized to launch specialists as needed. Successor t49 product-manager verified Claude Opus5.5 (argv + readiness response) and read the current handoff. Sole PM authority transfers with explicit HANDOFF_GRANTED from t1r; afterward reports route to t49/product-manager, t1r stops coordinating/writing. Same dedicated PM worktree/PR46 branch is handed over cleanly. See handoffs/claude-pm-2026-11-15.md and roles.json; these supersede older dispatch below.

**New binding split:** Developer owns production code and unit/logic/regression tests/build CI. QA is functional from here: actual app/user workflows/artifacts, reproducible defects/evidence/limits; no new unit-test or core-linked unit-style QA harness assignments. Existing evidence preserved.

Current PR48 DRAFT head52d5124384817b63dc6d3ee2d58dcd4b9491ba45, CI43740674826 SUCCESS317tests/externalAPI/universal/render/upload; actual PR Intel smoke SKIP. Current-head Copilot5911935714 no open issues/all threads resolved, human fd-test scheduling caution recorded without reproduced failure. Scope CORE/transport only; no Settings/AppModel/discovery/clip wiring. Developer t1s source/debug completed HELD/clean in developer-scope-core, idle. Codex QA t1t hit quota while finishing final actual-artifact verification: affected52 viewer checks passed and prior error/legacy/JSON/transport evidence retained; **final current-head acceptance not claimed**. New functional QA must close the remaining actual-build/artifact gate. No UI expansion or merge until new PM assesses current gates.

Mainc91 includes accepted PR47; #44 Done, #30 In Progress. PR46 holds planning/durable checkpoint docs; older state paragraphs are historical. Saved verified mainb0127f0 app/ZIP remains immutable. No releases/tags/Homebrew/auto-merge; prior ready-merge authorization conditional on review/checks/acceptance remains available to new PM.

---

# Team checkpoint — 2026-11-15 scope-core acceptance

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . Live state and exact-head evidence supersede this snapshot.

## Team

Sole PM t1r; reports use `hc send t1r`. Developer t1s `codex-developer` GPT-6.1 Sol/high; QA t1t `codex-qa` GPT-6.1 Sol/medium. Specialist models/efforts verified by argv, TUI and READY. PM local config is Sol/high; launch argv did not explicitly select its model. Designer/developer-2 idle. QA previously hit its limit after completed handoff QA, then resumed the same session successfully after the reported reset passed at20:19UTC; PR47 accepted and mergedc91c250; PR48 final verification active after same-session Nov15 recovery. No restart/model switch. Old Claude sessions exited cleanly, history preserved; do not restart them. Chris authorized Codex takeover and token-conscious choices; see roles.json and [initial takeover](handoffs/codex-takeover-2026-11-14.md).

## Merged and verified

- PR36 incidents/marker/outage simulator: accepted head `8c462b2673af0b6cafae7018d3e132f0b906d2d8`, merged as `9a533ec209eb703a2120a03c44fee6c409da748a`. Current-head CI/review and independent functional/still QA PASS (comment6879047123). #11/#37 Done.
- PR42 hover placement and settled drop: accepted head `0f720962d549185c0a04d928c2952ef7e9bc3da0`, merged as `b10d329e0036bc67a927a4b7e561765ef37312fd`. Separate fixes for non-finite diagnostics and repeated/far edge drops independently reproduced before/fixed after. CI43607798711 green277tests/render, final Copilot no open issues, independent actual-artifact QA PASS (comment6879421128). #39 Done.
- PR43 universal ZIP and provenance: accepted head `561fafc6705b4e587aa23327fc029f965edac33a`, merged as **`b0127f00e4dec92b5b9111a46b76c7191334706f`**. Full history/exact packaged SHA, push-only main artifact lookup and failed Intel-child smoke fixed. Independent actual integrated artifact QA PASS (comment6879599808); exact-head CI/review green.

## Saved app and ZIP

Actual push-to-main CI **43609749683 SUCCESS**:277 tests,8 packaging regressions, universal bundle, packaged-app render and actual x86_64 Rosetta smoke PASS. Entire source tree matches accepted561fafc exactly. Developer saved stable files without overwrite:

- `/Users/chris/github-pet-builds/b0127f0/GitHubPet.app`
- `/Users/chris/github-pet-builds/b0127f0/GitHubPet-0.1.0-b0127f0-universal.zip` and checksum sidecar
- `REPORT.md`, `VERIFICATION.json`, `codesign.txt`, `main-ci.log` alongside
- Version0.1.0, build71, full source revisionb0127f00e4dec92b5b9111a46b76c7191334706f; x86_64+arm64; strict ad-hoc signature;13 pack files match source.
- ZIP SHA256 `f427650c9624b64dc6a89871ffd952342dea429df10441c34ccf5968cf6952a5`.
- [Main artifact](https://github.com/christopherrbrown3/github-pet/actions/runs/43609749683/artifacts/14120062080).

Final independent main-artifact QA PASS: PR43 comment6879875192; checksum/all archive and app bytes/signature/architectures/build71/fullSHA/accepted tree/mascot bytes verified, actual Rosetta execution confirmed in fresh mainCI log. No duplicate local build or app launch; no user settings, permissions, quarantine or unrelated processes changed.

## Remaining scope

#15 stays open: app/ZIP packaging is delivered, broader native install/login/accessibility/distribution acceptance is not complete. Clean-Mac quarantined first launch and settings preservation, physical Intel, actual native popover chrome/manual pointer/VoiceOver and live motion remain unverified (#4/#15). Rosetta CI execution is not physical Intel evidence. No release, tag, Homebrew publication or auto-merge authorized/performed. Chris subsequently instructed PM to keep working. #44 Done: PR47 accepted exactbb44d7b47c300793b7a9ab30c73a9844b5f16f82, CI43633750212 SUCCESS278tests/render, Copilot no open code issues, independent96assertionQA PASS comment6883697587; mergedc91c250. Production stale/recovery semantics unchanged. #30 is In Progress: Developer plan accepted with explicit bounds and a fixtures/core/transport first slice; see features/30-monitoring-scope.md. No Settings/AppModel/clip-queue wiring authorized until that slice is reviewed. #35/#40/#41 remain Backlog. PR47 accepted and mergedc91c250f176afca5090d17c82c4205ecffe5c793; #44Done. PR48draft currente2a11a559bfbfb791fcd68cd4aa37d77f1f4ce72 integrates that main. Original940 CI failed cancellation ordering; controlled repro showed cancel requested after deadline, fixed test handshake without production cancellation change. Public budget accounting exposed and external normal-import test added; full-JSON newline ID defect independently confirmed before/fixed by byte validation. CurrentCI43639314358 SUCCESS306tests, external API check, universal build/render; final independentQA still underway. Both agents hit Nov14 7:10PM usage limit, then resumed same sessions/models on Nov15 after verified reset elapsed. No bypass/restart.

PM documentation PR45 merged as645950cb918e9327513ed8e363f732d0087f81c5 after doc QA/currentCI/Copilot PASS. Current PM continuation branch docs/30-monitoring-scope-brief records the next scope proposal and revised assignments. Earlier handoff sections are historical, not current active assignments.

## PR48 final-head QA rework — 2026-11-15

Exacte2a11a559bfbfb791fcd68cd4aa37d77f1f4ce72 is **FAIL/HOLD**, not accepted: independent report https://github.com/christopherrbrown3/github-pet/pull/48#issuecomment-6897888441 (QA37ea066). CI43639314358 SUCCESS306tests/external normal-import/bundle/render remains supporting evidence. Independent18full-JSON after-cases and36/37 adversarial checks passed, including corrected byte validation/public API/shared collection budget/deadline/cancellation. Remaining L1: real child returns valid empty JSON thenexit7; legacyGhClient still reports completeempty, whileScopedGhClient rejects success. L2: source confirms legacyparser discards nonempty/malformed GraphQLerrors, allowing complete results evenexit0. Both were pre-existing inc91; both are directly in the agreed two-client quality contract and must be fixed narrowly before acceptance.

QA finished all e2 links and explicitly released the held build to Developer. Developer is authorized a separate quality-path commit/regressions only (nonzero exit and error-envelope completeness; preserve proven partial rows where appropriate), then one new CI/current review and new completed immutable handoff. No Settings/AppModel/clip/discovery expansion, no saved-app change, no old-artifact acceptance. Final QA awaits the new exact head.
