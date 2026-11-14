# PR43 independent exact-head QA

Head `f54d5a6deb1db6c6ec3e87361431d4222dbd6a64`, CI run `43606183925`.

**Verdict: FAIL / hold for D2 below.** QA D1 is fixed and the actual green CI artifact passes the scoped packaging checks. No merge-ready acceptance at this head.

## Actual CI artifact: PASS

CI [43606183925](https://github.com/christopherrbrown3/github-pet/actions/runs/43606183925) SUCCESS. Independently downloaded `GitHubPet-app` (artifact ID 14118094522) into a fresh empty QA directory, extracted using ditto and verified its contents. The artifact expires 2026-11-28 (14-day PR retention).

- ZIP `GitHubPet-0.1.0-f54d5a6-universal.zip`; SHA-256 `e0dd61f8207b30e7e08d8f737c69f11bcea87e0d0781e23a0933d80128aefeda`; independently computed digest and shipped checksum agree.
- Extracted bundle passes `codesign --verify --deep --strict --verbose=2`; signature is ad-hoc, TeamIdentifier unset. `lipo`: x86_64 + arm64.
- Signed Info.plist: version 0.1.0, build **51** (independent full-history count), source revision **f54d5a6deb1db6c6ec3e87361431d4222dbd6a64**, bundle id dev.github-pet.GitHubPet, LSUIElement true, minimum macOS 13.0.
- All 12 bundled mascot frames and manifest match exact source bytes.
- Actual CI log proves build/tests used combined branch `ff8be8c` (merge of f54d5a6 into 83b7b5c), **164 tests PASS**; then packaging checkout selected f54d5a6. Provenance assertions/regressions passed and packaging printed build 51/full source SHA. GUI render-check passed, with positive gesture skipped because the runner's system Reduce Motion is ON. Intel smoke is skipped by the PR-event condition.

## D2: Intel smoke accepts a crashed child

PM routed a final-head Copilot finding: `scripts/intel-smoke.sh` discards `wait` failure with `|| true`, then accepts a usable report even if the child failed. Independently reproduced against the exact-head script in an isolated fixture: a child writing the expected baseline report then exiting **86** gives smoke exit **0**, the same result as a successful child. No real app/Rosetta invocation was used; local PATH stubs isolate process/report handling. See `smoke-exit.log` and `scripts/qa/pr43-smoke-exit.py`.

This is a reproducible false-positive smoke check, not evidence that the actual app crashed. Developer is fixing it in a separate commit; re-run the same positive/negative fixture against the new exact head, reuse unaffected f54 packaging evidence, and verify the new CI status/artifact provenance before final acceptance.

## Guards and source review: PASS

Completed: unchanged exact-head detached checkout; source delta review; six developer packaging regressions independently rerun; two additional missing-Git entry-point guards; complete-history count independently verified as 51; shell syntax and diff whitespace checks pass. No local app compilation. Full/depth-1/depth-2 fixture clones exercise both build and packaging entry points; shallow/missing history is rejected before Swift or build output.

Copilot 4572352217: CLI lookup adds `--event push`, main and success filters; null/empty run guard prevents downloading without a match. Browser instructions also identify repository main push runs. Actual filtered read-only lookup returned push run 43533179320 at main 83b7b5c; no download from that old pre-packaging run was claimed.

Copilot 4572352235 / QA D1: both CI checkouts fetch full history; combined-branch build/tests precede a PR-head checkout for packaging/rendering. Expected SHA, non-shallow history and count >1 assertions precede packaging. Build guard tests depth 2 as well as depth 1, so count >1 alone cannot hide a truncated checkout. Signed plist now includes full `GitHubPetSourceRevision`, checked after archive extraction.

Development Gatekeeper advice now links install.md's Open Anyway flow and explicitly states clean-Mac quarantined first launch remains unverified. No quarantine, system settings or permission changes; no physical Intel or clean-Mac acceptance claimed.
