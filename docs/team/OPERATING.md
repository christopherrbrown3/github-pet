# Operating the team

GitHub Projects V2 is the intended durable system of record. Status sequence: Inbox → Backlog → Ready → In Progress → In Review → In QA → Done; Blocked is explicit. Fields: Owner Agent (role), Priority, Type, Milestone. PM alone updates assignment and status. Until Project scope authorization completes, issues and comments preserve all assignments; do not claim board synchronization.

## Bootstrap sessions

Herdr Core 0.1.20 (`hc`), Codex 0.167.2, Claude Code 2.1.311. The old `herdr` executable is absent. Existing PM t8 displays GPT-6-Astra. Developer t9 uses claude-opus-5-5; designer t10 uses gpt-6.1-sol; QA t11 uses gpt-6-luna. All three replied through hc send t8. Designer exercised actual image generation and alpha validation. Generation/edit tools are exposed; editing must be verified when used.

All four appear in one GitHub Pet Team tab, in a 2×2 arrangement. Session addresses are observations, not permanent identities. Inspect `hc ls`, `hc get` and `herdr-app ls` before routing. A stale inherited HC_TERMINAL_ID was observed (t2 rather than live PM t8); use the observed current parent explicitly.

## Work ownership

| Role | Branch | Worktree | Initial issue |
|---|---|---|---|
| product-manager | bootstrap/agent-team-kickoff | coordinator checkout | #5 |
| developer | sprint1/native-prototype | ../github-pet-worktrees/developer | #2 |
| graphic-designer | sprint1/mascot-design | ../github-pet-worktrees/graphic-designer | #3 |
| qa-engineer | sprint1/qa-acceptance | ../github-pet-worktrees/qa-engineer | #4 |

Launch directories initially pointed at the coordinator checkout; scoped dispatch explicitly requires worktree-specific working directories for every file/command. Check actual changes, not terminal header cwd.

## Management loop

1. Inspect Project items, linked issues/PRs and dependencies using gh. Pick only ready, unblocked work.
2. Check hc session state and reported status. Use roles, not model names, for assignment.
3. Send scoped task with issue, branch/worktree, allowed paths, acceptance criteria, report destination and no-merge rule via `hc send <agent> <task>`.
4. Continue PM work; use `hc wait <pm> --children any --timeout 45` for events. `hc read <agent>` collects evidence. Do not infer completion from silence.
5. Record exact SHA, deliverable/PR, checks and limitations in the issue. Advance to In Review only when deliverable exists.
6. Request Copilot review if available. Route exact SHA to independent QA. Status In QA means verification is underway, not that it passed.
7. QA posts pass/fail/blocked evidence and reproducible defects. Send defects to Developer; verify new SHA with QA again.
8. Mark blocked with reason and recovery owner when external input is needed. Preserve ready work. Never bypass model usage limits.
9. Done requires acceptance evidence and any required owner approval. Bootstrap PRs remain unmerged until Chris explicitly authorizes merge.
10. Dispatch next authorized ready task. On shutdown, post current role/session/PR/status snapshot on #5 and each active issue.

## Recovery

Read `hc --skill` after a restart. Inspect live sessions before launching anything; never duplicate PM or kill unrelated terminals. `hc keep` replaces a lost process with a shell, not a restarted agent. Specialists were launched with `--outlive-parent` and keep enabled. Sessions survive coordinator exit, but an idle agent does not self-dispatch work.

For a dead specialist, inspect its saved CLI session, worktree status and issue checkpoint. Resume the same session with its exact model where supported, or launch a fresh interactive session in its worktree with role instructions and the saved task. Codex MUST use `--no-daemon`; background agents use `hc run --bg`. Never use one-shot print mode. Do not automatically restart a task that may have already committed or opened a PR.

Example runtime commands (append the saved role/task instructions):
- Developer: `claude --model claude-opus-5-5 --name developer --permission-mode auto`
- Designer: `codex --no-daemon -m gpt-6.1-sol`
- QA: `codex --no-daemon -m gpt-6-luna`

Verify launch argv, displayed model and an actual response before reporting operational. Trust prompts may be resolved only within the user's authorized project. Read blocked/error screens; do not force past permission decisions. No service restarts or usage-limit workarounds.

## Environment limits

Swift 6.2.3 and Command Line Tools are present. Full Xcode is absent, so xcodebuild is unavailable. SwiftPM build/test and locally assembled .app are the prototype route; signing/notarization is not claimed. GitHub Projects requires project scope on gh; keep its authorization blocker visible until verified resolved.
