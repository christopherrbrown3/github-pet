# PR43 independent exact-head QA

Head `f1cfada8aeb28588e86952d39496f0cfeee03c34` (remote rechecked); CI [43606856503](https://github.com/christopherrbrown3/github-pet/actions/runs/43606856503) **SUCCESS**.

**Verdict: PASS for packaging/provenance and D2 fix.** No remaining reproducible scoped defect. Clean-Mac browser-quarantined first launch and physical Intel remain **BLOCKED / unverified**, not installation or hardware acceptance.

Delta from `f54d5a6` is limited to `scripts/intel-smoke.sh` and focused tests in `scripts/test-packaging.sh`. No app, workflow, packaging or install-doc changes. Parent exact-head artifact evidence is retained in `../pr43-f54d5a6/REPORT.md`.

Independent negative probe rerun against the unchanged exact-head smoke script: a fixture child writes a valid baseline report, then exits 86; script now exits **86** and diagnoses the failure. Child exit 0 still gives smoke exit **0**. Before the fix the same probe returned [0,0]; now [0,86]. This is isolated process/report handling via local architecture stubs, not actual Intel or Rosetta execution. All eight developer focused regressions independently rerun PASS (two child-status cases, six full/depth-1/depth-2 packaging guards). No app build or broad test sweep.

## Actual new CI artifact: PASS

After the existing Developer watcher t24 completed successfully, QA independently downloaded the actual `GitHubPet-app` into a fresh directory and extracted it with ditto. No local universal rebuild.

- ZIP `GitHubPet-0.1.0-f1cfada-universal.zip`; computed/shipped SHA-256 agree: `c5325114adc71af2fe51b1524535765f7927d2e9bc3307f3cd4feabcf7ec1ac6`.
- Signed plist: version 0.1.0, **build 52**, exact source revision **f1cfada8aeb28588e86952d39496f0cfeee03c34**. Independent complete-history count is 52. Bundle ID dev.github-pet.GitHubPet; minimum macOS 13.0; LSUIElement true.
- `codesign --verify --deep --strict --verbose=2` passes; ad-hoc signature, no TeamIdentifier. `lipo`: x86_64 + arm64. Manifest and all 12 mascot PNGs match exact source bytes.
- Actual CI log: first checkout combined branch `2840f68` (f1cfada merged into 83b7b5c), **164 tests PASS**; second checkout f1cfada for packaging; provenance assertions and all eight regression cases PASS; package source/build metadata correct; GUI render-check PASS.
- Intel smoke is skipped on this PR event. Positive gesture probe is explicitly skipped because runner system Reduce Motion is ON. Neither is counted as a positive desktop or Intel run.
- Current-head Copilot review 5905086871 reports no open issues and repeats the clean-quarantined-first-launch limitation. The previous review header did not override D2; it was independently reproduced and is now behaviorally fixed.

Parent D1 fixes remain verified: full-history rejection guard, signed full source revision, PR-head packaging after combined-branch tests, push-only main artifact lookup with missing-run guard, and corrected development Gatekeeper instructions. Their source is unchanged from the inspected f54d5a6 parent.

Logs, summary and isolated probes are in this report's directory / `scripts/qa/`; QA evidence commit is separate from production. No system preferences, permissions, quarantine changes, app launch, merges, tags or releases. PM owns integration/merge decisions; this acceptance applies only to the exact head above and must be carried through any later integration delta review.
