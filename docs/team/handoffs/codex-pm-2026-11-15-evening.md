# Codex PM return — 2026-11-15 evening EST

Claude PMt49 granted sole ownership to Codext1r after Claude allowance reached its limit (reset9pm). Per t49, Chris explicitly instructed “if usage limits get close, use Codex; if your own usage is nearing its end, hand over.” t1r acknowledged via Herdr and verified live state. Current actual mapping is roles.json/live hc; do not route to retired product-manager alias (t49). Reports to hc send t1r.

Developer owns unit/logic/regression tests/build CI. QA FUNCTIONAL only: actual built app/test-runner actions, user-visible PNG/JSON, isolation/artifact verification and defect reports. No unit/core-linked harness authoring by QA. Preserve prior evidence. No release/tag/auto-merge/Homebrew, force pushes or internal org details. Ready merges remain authorized after current-head review/CI/functional acceptance.

## Verified handoff corrections

- PR48 mergedf997d1d. Main has accepted core/transport; #30 still in progress.
- PR49 application sliceA exact0f0c65c59b379b9bd31860b689fb79ddb7937f6c: greenCI43779938258. Latest exact-head Copilot has no inline open issues but concrete critical summary: hard-linked QA output can overwrite a file outside its directory. Source confirms openat O_TRUNC follows hardlinks despite O_NOFOLLOW. **NOT merge-ready.** Codex Developer t53 Sol/high now fixes only this output writer/guards with private-sandbox negative-before/regressions, then one CI/re-review. Do not treat no-open-issues header as acceptance.
- PR50 fixes40 exact33f36f12a3f51b87d58df2c907a5cb8690d4ca63: greenCI43775715168; ClaudeQA unfinished helper t52 qa-pr50b-run still sequentially rendering hostile pack cases. Codex functionalQA t55 Sol/medium inspected/preserved helper, existing untracked evidence and saved app. Ten stderr captures and selected PNGs inspected, no full PASS. Checkpoint https://github.com/christopherrbrown3/github-pet/pull/50#issuecomment-6904125028 . Do not duplicate app runs/kill old helper or claim final exit/isolation/fallback acceptance yet.
- PR51 native Settings/discovery exact03bd31806a9cf9686efdfc20842019210ad81147: green on older PR49 base; baseRef feat/30-scope-ui. Hold until49 ready, then integrate accepted49/main history-preservingly and revalidate. Handoff said rebase; **no force pushes allowed**, use merge/retarget as appropriate, no published-history rewrite.
- PR53 for52 ALREADY EXISTS (handoff said not opened): exactad926aeffff240829f2b4da00739d9918bf87dc8, oldCI green. Copilot4580958161 valid: setup captures inject CLI failures but Source remains Fixtures. Codex Developer t54 Sol/medium fixing snapshot-only actualCLI source via offline provider/trap, retaining read-only fixed setup links/copy. Local candidate09b260a; targeted checks/render helper pending, not pushed yet at this checkpoint. No install/ghauth/network/settings changes.
- #35 Ready after49 merges, decision comment6903109382; #41 decisions comment6903571698, small weak-container/guard-now PRs later, popoverDidClose only if reproduced. Not dispatched now.

## Functional runner and isolation

Read developer-scope-ui/docs/monitoring-scope-application.md at actual accepted head. PR49 built app supports explicit offline --simulate-monitoring-scope --qa-scenario one-of-eight --qa-output fresh-empty-dir, producing actual-view offscreen PNG and JSON, then normal quit. Simulated identity/scopes are invented, memory-only, no gh/network. QA must judge behavior from outputs, not runner exit0. Native mouse/AX/composited desktop/motion are not proved by offscreen PNGs.

Before reusing scripts/qa/scope-scenarios.sh, correct stale schema assumptions: actual runner emits multiple -inbox/-mascot PNGs plus summary JSON, not simple one-PNG-per-JSON; custom .json scenarios should be passed as file paths as supported, not assumed inline strings. Do not invoke old kill-9 branch; normal quit/path-verified owned test PID only, report hang. QA t55 owns functional scripts/docs, no production fix. Preserve existing untracked pr50 evidence.

Saved user app /Users/chris/github-pet-builds/b0127f0/GitHubPet.app pid31897 is RUNNING; leave it and real settings untouched. One QA app at a time, apart from that preserved user app. About516 old dev.github-pet preference plists are Chris's decision: no global cleanup, deletion or permission changes. Helpers/new scenarios must not add stale domains.

## Current dispatch

PM t1r in clean dedicated product-manager worktree/branch docs/30-monitoring-scope-brief; PR46 remains PM planning/checkpoint draft. Developer t53 codex-dev-runner (Sol/high) owns developer-scope-ui; Developer t54 codex-dev-setup (Sol/medium) owns developer-gh-setup-link; functionalQA t55 codex-functional-qa (Sol/medium) owns qa-engineer after Claude t4x interruption. All verified READY. No extra agents without PM assignment. Stopped old Codex t1s/t1t and Claude t49/t4w/t4x/t4y/t4z are preserved and not current writers. Never silently substitute models or bypass allowance; user explicitly authorized this switch.

Next gates:49 output safety fix/current CI; QA finish50 existing evidence then actual49 eight scenarios (and bounded meaningful ordering variants). After49 acceptance/merge, integrate51 once, verify settings-* functionally.53 follows current-head functional evidence. Do not merge merely conflict-free/green.
