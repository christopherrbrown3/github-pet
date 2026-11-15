# PR48 independent exact-head QA checkpoint

Head **`52d5124384817b63dc6d3ee2d58dcd4b9491ba45`**, CI43740674826 pending. **Affected viewer compatibility/guard checks PASS; final acceptance waits actual current-head CI/review.**

Exact clean source and completed/held build verified before linking; module/core object hashes recorded and unchanged after QA. Diff from4b contains only ScopedGitHub.swift's separate viewer-display validator and MonitoringScopeTests.swift coverage. Organization/repository grammar, node-ID identity, query argv, expected-account guard, errors policy, transport and legacy behavior remain unchanged.

Independent normal-import **68 assertions PASS** through actual public parser and ScopedGhClient fixture calls:

- Same four original4b negative-before EMU cases (`fixture-user_demo`, `demo_admin`, Everything/selected) now succeed with valid nodeID and preserved display text.
- Ordinary, EMU/setup, case-preserving and39-character boundary displays succeed in fresh Everything, bound Everything and selected scope. Each keeps the same immutable account identity; login remains display metadata.
- Missing/empty/embedded-space/newline/40-character login values reject; valid EMU display cannot bypass node-ID rejection.
- Different valid viewer ID in bound Everything or selected mode returns identityMismatch and discards submitted results. Organization/repository-owner underscores remain invalid; no target/query grammar expansion.

Scope of this rerun is only the display-validator delta. Retain44 scoped-errors parser/client assertions,98 legacy quality assertions,18 full-JSON ID-rejection assertions, four CI-owned legacy incomplete/budget regressions and original passing real-pipe/identity/partial/corruption/cancellation evidence by unchanged implementation; do not present those as new52 executions. All negative-before reports remain preserved.

One event wait uses existing Developer watcher t46 for current CI43740674826, then downloads actual current-head render evidence/log. Superseded4b CI independently confirmed cancelled; no old artifact accepted. No live auth/account/settings changes, saved app/process changes, UI wiring/expansion, broad suite/render/universal build, system clock/privacy changes, merge or release. Core/transport acceptance only; final current-head verdict pending.
