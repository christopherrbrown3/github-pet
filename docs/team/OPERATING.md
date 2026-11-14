# Operating the team

## Current dispatch — 2026-11-14

Chris explicitly authorized Codex PM and specialists with cost-conscious model selection. This supersedes historical Claude-only model instructions below. Read [the current takeover](handoffs/codex-takeover-2026-11-14.md), [CHECKPOINT.md](CHECKPOINT.md) and roles.json. Sole PM is **t1r**; reports go to `hc send t1r`. Active specialists: `codex-developer` t1s (Sol/high) and `codex-qa` t1t (Sol/medium), both verified by launch argv, TUI and READY. Old role names still target preserved Claude sessions, so do not route to those names. Designer/developer-2 remain idle to conserve usage. Never launch duplicates or automatically switch models.

GitHub Projects V2 is the durable system of record: https://github.com/users/christopherrbrown3/projects/3/views/1 . Status sequence: Inbox → Backlog → Ready → In Progress → In Review → In QA → Done; Blocked is explicit. Fields: Owner Agent (role), Priority, Work Type, Milestone. GitHub reserves Type; Work Type provides the requested epic/feature/task classification. PM alone updates assignment and status. Project-scope authorization completed; issue comments preserve exact-SHA evidence and handoffs alongside board status.

## Bootstrap sessions

Herdr Core 0.1.20 (`hc`), Codex 0.167.2, Claude Code 2.1.311. The old `herdr` executable is absent. At bootstrap, the team observed PM t8, developer t9, designer t10 and QA t11; these historical model/session observations have since changed. The current roles.json and live Herdr state take precedence. All three replied through hc send t8. The original Codex Designer t10 exercised actual image generation and alpha validation. That historical capability does not establish generation or editing access for the Claude replacement.

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
9. Done requires acceptance evidence and any required owner approval. Chris now authorizes merging ready PRs after review findings are handled; validate the current SHA and required acceptance first.
10. Dispatch next authorized ready task. On shutdown, post current role/session/PR/status snapshot on #5 and each active issue.

## Recovery

Read `hc --skill` after a restart. Inspect live sessions before launching anything; never duplicate PM or kill unrelated terminals. `hc keep` replaces a lost process with a shell, not a restarted agent. Specialists were launched with `--outlive-parent` and keep enabled. Sessions survive coordinator exit, but an idle agent does not self-dispatch work.

For a dead specialist, inspect its saved CLI session, worktree status and issue checkpoint. Resume the same session with its exact model where supported, or launch a fresh interactive session in its worktree with role instructions and the saved task. Codex MUST use `--no-daemon`; background agents use `hc run --bg`. Never use one-shot print mode. Do not automatically restart a task that may have already committed or opened a PR.

Example runtime commands (append the saved role/task instructions):
- Developer: `claude --model claude-opus-5-5 --name developer --permission-mode auto`
- Designer: `claude --model claude-opus-5-5 --name graphic-designer --permission-mode auto`
- QA: `claude --model claude-opus-5-5 --name qa-engineer --permission-mode auto`

Verify launch argv, displayed model and an actual response before reporting operational. Trust prompts may be resolved only within the user's authorized project. Read blocked/error screens; do not force past permission decisions. No service restarts or usage-limit workarounds.

## Environment limits

Swift 6.2.3 and Command Line Tools are present. Full Xcode is absent, so xcodebuild is unavailable. SwiftPM build/test and locally assembled .app are the prototype route; prototype bundles are ad-hoc signed and verified; Developer ID signing/notarization is not claimed. GitHub Projects project scope was verified available after authorization. Inspect gh auth/permissions if future board requests fail.

## Current recovery checkpoint

Read [CHECKPOINT.md](CHECKPOINT.md) and [roles.json](roles.json) before resuming. They supersede historical session addresses and old build SHAs above. After usage exhaustion, preserve work and stop retrying until reset or an authorized external change; restarting does not reset the allowance. All restarted agents must keep the latest user-authorized models and prove a response. Chris explicitly selected Terra for Designer. Never substitute a cheaper model to bypass limits.

Use a fresh verification worktree pinned to the exact implementation SHA. Pushing a feature branch does not invalidate a detached old-SHA checkout or saved report. Keep one QA app version running at a time; never mix observed results across SHAs. Save a short checkpoint after each functional group so unfinished acceptance survives interruptions. Offscreen render checks validate rendered output, not menu-bar interactions, pointer behavior or animation timing.

The first two PRs (#16 workflow, #17 QA plan) were already merged externally when inspected; this coordinator has not merged them. PR #18 implementation and #19 design remain open at the checkpoint. Chris subsequently authorized merges of ready PRs after Copilot findings are reviewed/handled. Releases remain unauthorized.

## Model-selection reminder hazard

During low allowance, Codex showed an idle popup whose default action was to switch from Sol to Luna. A pasted prompt followed by Enter can accept that default before the task reaches the agent. This explains an observed Designer model mismatch. Inspect the visible screen when readiness or model identity is uncertain; dismiss the suggestion with Keep current model (never show again) rather than accepting the default. Verify the model after dismissal. This changes reminder behavior only; usage limits remain in force. Never use a model switch to bypass an allowance.

## Claude specialist takeover

Chris requested Claude replacements for QA and Designer. Both now run Opus5.5 in dedicated role worktrees; see [handoff](handoffs/claude-specialists.md) and roles.json. Original Codex sessions ended cleanly and their worktrees/evidence remain. Both replacements verified gh, Swift, hc and image inspection; neither has CUA enabled, and Designer image generation is unavailable/unverified. Do not infer old Codex tools carry across runtimes. Chris authorized PM to launch a scoped Codex artist if image generation or editing is needed; no artist is currently required.

Chris then requested a Claude Product Manager. Claude Code t1p (claude-opus-5-5) accepted the handoff from Codex t8 and is now sole PM. Specialists report through `hc send product-manager`. Their Herdr parent is still t8, so do not rely on parent notifications.
