# Codex PM takeover — 2026-11-14

Chris explicitly requested a new Codex PM and Codex specialists, selecting models to conserve tokens while maintaining product quality. This supersedes earlier Claude-only model instructions. PM is t1r; send reports to `hc send t1r`, never the retired Claude PM.

## Evidence and state

Read the Claude PM saved history `509dc436-e621-4025-b7f4-b02119a92a5b` and live GitHub board/PRs. Prior Claude terminals t1p (PM), t9 (Developer), t1m (QA), t1n (Designer), t1q (developer-2) are preserved. Auto-resume waiting was cancelled with Escape on the three quota-paused terminals. Do not resume those agents or assign them work concurrently.

- Main includes prototype PR18 (merge 83b7b5c). No release authorized.
- PR36 `8c462b2673af0b6cafae7018d3e132f0b906d2d8`: incidents, separate marker, expanded fixture outage simulator. CI43579009400 green, 274 developer tests; independent final-head QA still required. Four Copilot threads have fixes but remain unresolved pending verification. Earlier design review passed 84a0e30 stills; live motion remains unverified.
- PR42 `56b071ca6050f30e95327d460cdd69fed984de2c`: hover-label clearance and settled drag origin. Independent QA PASS, including negative overlap probe: https://github.com/christopherrbrown3/github-pet/pull/42#issuecomment-6877169288 . Preserve evidence; don't repeat the oversized QA sweep.
- PR43 `f85d5c1102646161150a14bc485cff475866a178`: universal app ZIP, CI green. Independent QA FAIL D1: shallow checkout makes build number always 1; PR ZIP uses ephemeral merge SHA. https://github.com/christopherrbrown3/github-pet/pull/43#issuecomment-6877616529 . Fix before acceptance. Actual Intel Rosetta smoke succeeded on manual run43569471978; physical Intel and clean-Mac quarantined first launch unverified.

## Dispatch and priorities

Developer: GPT-6.1 Sol, high effort. Resume existing clean developer worktree/feat/15-zip-packaging; fix PR43 D1 and obsolete Gatekeeper guidance, targeted validation, push without force. Then wait for next scoped assignment.
QA: GPT-6.1 Sol, medium effort, independent. Resume final-head PR36 verification using preserved qa-verify-8c462b2 artifacts where sound. Report exact-head verdict, four Copilot fixes, fixture simulator lifecycle, unknown/stale/failure semantics and marker suppression. Use bounded tests; no dense sweep. Then verify PR43 fix when PM supplies SHA.
Designer and developer-2 remain unlaunched/idle: their delivered work is preserved; no new assignment currently justifies extra agents. Escalate only a concrete difficult task, explicitly recording any model change.

Keep PR36 first in integration order, then PR42 and PR43, verifying current heads, reviews, CI, conflicts and QA each time. Prior PM history records Chris authorizing ready merges; no auto-merge, release/tag, or Homebrew publication. Current request is takeover, not broad backlog expansion. Preserve #35/#40/#41/#44 in Backlog.

## Boundaries

PM alone owns board and dispatch; Developer owns Swift/tests/build CI; QA owns docs/qa and scripts/qa. gh CLI only for authenticated GitHub. Native SwiftUI/AppKit, read-only product, no stored tokens or organization details. Never label unknown/partial/stale/error as empty. Fixtures default; baseline/recovery silent, new events once. Do not change system privacy, Reduce Motion or Gatekeeper settings, manipulate quarantine or kill unrelated processes. Offscreen renders aren't live desktop acceptance.

Report readiness (model/effort/terminal/worktree), then exact SHA, PR, validations, limitations and handoff through Herdr and durable GitHub comments. No subagents. Save checkpoints after functional groups. Run heavy work in background Herdr terminals with logs, avoid duplicate builds and repeated full tests.
