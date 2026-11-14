# Team checkpoint — 2026-11-14 Codex takeover

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . Live board and exact-head GitHub evidence supersede this snapshot.

## Active team

- Sole PM: t1r, current Codex session, local config Sol/high (launch did not explicitly select a model). Branch `docs/codex-pm-takeover-20261114`, worktree `product-manager`.
- Developer: t1s `codex-developer`, **gpt-6.1-sol / high**, verified argv/TUI/READY. Worktree `developer`, branch `feat/15-zip-packaging`.
- QA: t1t `codex-qa`, **gpt-6.1-sol / medium**, verified argv/TUI/READY. Worktree `qa-engineer`, detached verification worktrees preserved.
- Designer and developer-2 idle; no extra agent launched for delivered work. Plan Sol/medium for a future scoped design review.

Chris explicitly requested Codex takeover and token-conscious model selection. See [handoff](handoffs/codex-takeover-2026-11-14.md) and roles.json. Preserved Claude terminals t1p/t9/t1m/t1n/t1q are historical, not active owners. Cancelled automatic quota retry on t1p/t9/t1m. Reports MUST use `hc send t1r`, not the retired `product-manager` name.

## Work and gates

- Main: PR18 merged as `83b7b5c`; prototype exists. No release/tag authorized.
- PR36: `8c462b2673af0b6cafae7018d3e132f0b906d2d8`, CI43579009400 green, 274 Developer tests. QA independently verifying current head and four outstanding Copilot fixes. Includes outage simulator and separate incident marker; unknown/stale/failure never means empty. #11/#37 In QA.
- PR42: `56b071ca6050f30e95327d460cdd69fed984de2c`, existing independent QA PASS, including deliberate-overlap negative probe. #39 remains In QA pending integration.
- PR43: `f85d5c1102646161150a14bc485cff475866a178`, CI green but QA FAIL D1 (build number1 from shallow checkout; temporary merge-SHA ZIP provenance). Developer fixing D1 and both Copilot findings, including limiting advertised main downloads to push events. #15 In Progress for rework. QA will verify new immutable head.
- Integration order retained: PR36, then42, then43. Refresh current-head reviews/CI/QA and conflicts before each authorized ready merge. No auto-merge or release.
- #35/#40/#41/#44 remain Backlog; no unsolicited expansion.

## Evidence limits

Offscreen render checks and static review are not native popover, pointer, VoiceOver or live motion proof. No current claim of clean-Mac quarantined first-launch verification or physical Intel validation. Intel Rosetta smoke did run successfully in manual CI43569471978 (prior QA comment lacked this later evidence). No system settings, permission, quarantine or unrelated process changes authorized. Avoid heavy dense QA sweeps; save logs/checkpoints and reuse valid exact-SHA evidence.
