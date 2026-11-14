# Team checkpoint — 2026-11-14 continued product work

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . Live state and exact-head evidence supersede this snapshot.

## Team

Sole PM t1r; reports use `hc send t1r`. Developer t1s `codex-developer` GPT-6.1 Sol/high; QA t1t `codex-qa` GPT-6.1 Sol/medium. Specialist models/efforts verified by argv, TUI and READY. PM local config is Sol/high; launch argv did not explicitly select its model. Designer/developer-2 idle. QA previously hit its limit after completed handoff QA, then resumed the same session successfully after the reported reset passed at20:19UTC; PR47 verification active, PR48 queued. No restart/model switch. Old Claude sessions exited cleanly, history preserved; do not restart them. Chris authorized Codex takeover and token-conscious choices; see roles.json and [initial takeover](handoffs/codex-takeover-2026-11-14.md).

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

#15 stays open: app/ZIP packaging is delivered, broader native install/login/accessibility/distribution acceptance is not complete. Clean-Mac quarantined first launch and settings preservation, physical Intel, actual native popover chrome/manual pointer/VoiceOver and live motion remain unverified (#4/#15). Rosetta CI execution is not physical Intel evidence. No release, tag, Homebrew publication or auto-merge authorized/performed. Chris subsequently instructed PM to keep working. #44 is In Review: PR47 exactbb44d7b47c300793b7a9ab30c73a9844b5f16f82 contains separate monotonic-duration and snapshot-only freshness commits; targeted2+4tests PASS, CI43633750212 pending, Copilot no open code issues; independent QA still pending. Production stale/recovery semantics unchanged. #30 is In Progress: Developer plan accepted with explicit bounds and a fixtures/core/transport first slice; see features/30-monitoring-scope.md. No Settings/AppModel/clip-queue wiring authorized until that slice is reviewed. #35/#40/#41 remain Backlog. QA resumed after reset and is independently checking47 then48; both heads remain held until acceptance. PR48draft940231dc1a794dcf221449e8df1a441718b1ca3f implements approved core/transport only; CI43636679960 pending.

PM documentation PR45 merged as645950cb918e9327513ed8e363f732d0087f81c5 after doc QA/currentCI/Copilot PASS. Current PM continuation branch docs/30-monitoring-scope-brief records the next scope proposal and revised assignments. Earlier handoff sections are historical, not current active assignments.
