# Sparkle decision — Chris, 2026-11-20

Chris approved Sparkle 2 automatic updates during the beta on the current ad-hoc builds. Users approve the first launch once with Open Anyway, and Sparkle installs later updates, verified by EdDSA. Developer ID signing and notarization (#89) are deferred until after the beta; #89 is in Backlog. Chris generates and backs up the production EdDSA key in his login Keychain. Agents never handle the private key; only the public key is committed. t6j now implements Sparkle for #90. PR91 (#88 icon assets) merged as fbae373 after QA PASS and green exact-head CI; designer t6k ended. Full decision: issue #90.

# Claude takeover — 2026-11-20

Chris directed a Claude takeover: Codex is out of weekly usage (6% left, resets Nov 24). Sole PM is **t6f**, Claude Opus 5.5, in the product-manager worktree; route reports with `hc send t6f`. Codex PM t1r had published and verified Beta.3 (tag v0.1.0-beta.3 at main 96b70d0, CI44562563081, ZIP f1a97e2c…). All Codex terminals (t8, t1r, t1s, t1t, t68, t69, t6b, t6d) and quota-parked Claude terminals (t4w–t4z, t61–t64) were ended and finished terminals removed from Herdr. Every worktree, branch and evidence directory is preserved.

New issues #87–#90 were added to Project 3. Fresh Claude specialists start from main 96b70d0, verified by launch argv:
- **t6h** developer, Opus 5.5: #87 Inbox redesign, `developer-inbox-87`, `feat/87-inbox-redesign`.
- **t6g** developer-2, Sonnet 5.5: #87 Settings Mascot/Alerts/GitHub panes, `developer-settings-87`, `feat/87-settings-panes`.
- **t6j** developer-3, Sonnet 5.5: #90 phase 1 update check (public Releases list, no gh/token, open release page; no auto-install until #89), `developer-updates-90`, `feat/90-update-check`.
- **t6k** graphic-designer, Opus 5.5: #88 two or more vector icon directions for Chris to choose; packaging follows approval. `designer-icon-88`, `design/88-app-icon`.
- **t6m** qa-engineer, Sonnet 5.5: functional acceptance plan for #87/#90, then exact-SHA review. `qa-nov20`, `qa/nov20-claude`.

#89 is Blocked on Chris's distribution decision (free ad-hoc vs paid Developer ID + notarization). Model choice: Opus where design judgment or product-invariant risk is high, Sonnet for well-specified slices and QA. Merge gates are unchanged: exact-head green CI that contains current main, independent QA acceptance, `--match-head-commit`, merge commit. No releases without Chris.

# QA model update — 2026-11-19

Chris requested Luna for QA. Existing QA t6b now uses GPT-6-Luna at medium effort, verified in the TUI after an explicit session-only model change. Reuse this model for future QA launches unless Chris changes it. Worktree qa-nov18 and its evidence are preserved. Developers remain GPT-6.2 Sol high.

PR84 is in independent review at 9f0227fabaf63c66f75b728641b623c098e647de, based on main 00e1be4. It wraps the Partial Inbox quality explanation and exposes the existing Startup status to accessibility. Developer before/after fixture and nine focused checks passed. CI44497523577 is active. Independent exact artifact evidence and limitations remain pending.

# Post-beta.2 dispatch — 2026-11-18

Beta.2 is published and verified. The release tag points to main 00e1be4d0bb14f73782130ad15eb4a8f0cf19ca8, build 263 from main CI44440438255. PR79, PR76 and PR80/82 shipped. #77, #78 and #81 are Done. #30 was closed after QA confirmed PR48 and PR51 ancestry and existing accepted scope documentation. Historical PR46 remains a planning draft. Live account and native accessibility, clean install, upgrade, login-item and physical Intel evidence remain in #4 and #15.

Chris asked to continue the project and shared Little Chris references in #83. Designer t6d uses GPT-6.2 Sol medium in designer-little-chris-83, branch design/83-little-chris. The preserved ImageGen source has nine poses and SHA-256 a87cd707e04e8f06ee110dab68d6d176e46ba459163ed317ccab33c32d1128b1. Designer owns the transparent v1 frame pack and provenance. Developer t68 uses Sol high in developer-skin-83, branch feat/83-little-chris, for the Settings picker, safe persisted skin choice, live artwork swap and both bundled resource checks. Mona stays the default. QA t6b prepared independent artifact and product checks for both skins, fallback, no replay and reduced motion.

Developer t69 uses Sol high for a separate narrow polish slice on #60 and #15. Preserve Inbox width while showing long Partial explanations and expose the existing Startup login status as the toggle’s accessibility value. The system login-item behavior is unchanged. QA t6b will review the exact signed artifact when available. No new release requested. Continue no Copilot and one writer per worktree.

# Current authority and dispatch — 2026-11-18

Chris transferred sole PM authority to Codex **t1r**, GPT-6.2 Sol, after Claude reached its weekly limit. Route reports to `hc send t1r`. The prior Claude sessions t61–t64 are suspended with their worktrees and evidence preserved. This entry and live GitHub state supersede all earlier status snapshots below.

- Developer **t68** uses GPT-6.2 Sol, high effort, in `developer-assignment-77`, branch `feat/77-direct-assignment`, for #77 team versus direct assignments.
- Developer **t69** uses GPT-6.2 Sol, high effort, in `developer-dismiss-78`, branch `feat/78-dismiss-inbox-items`, for #78 persistent dismissal and restore.
- QA **t6b** uses GPT-6.2 Sol, medium effort, in `qa-nov18`, branch `qa/nov18-takeover`. It is continuing the independent PR76 review and preparing acceptance for both features. Historical QA at `qa-engineer` remains available as evidence.

The two feature worktrees start at main `7dfa0e264e353d0beca0cfe4bcb0d0a37c772a04`. Both issues are In Progress on Project 3. PR76 `bbc11fe0925c644320adbcf8c120b69b7cfdc86b` has green CI44155961676 against its original base but conflicts on README.md with current main. It needs a history-preserving integration and fresh CI before merge. Published beta.1 remains the current release.

QA independently reviews PR diffs and verifies product behavior. Developer owns production code, unit and regression tests, and build CI. Use installed gh for authenticated GitHub operations. Chris has prohibited Copilot reviews. Merge only after current-head green CI, head ancestry includes current main, and independent acceptance. PM uses `--match-head-commit` and a merge commit. Releases, tags, Homebrew publication and auto-merge require separate user direction.

# Checkpoint — t61, 2026-11-16 evening (beta RC)

All narrow-beta work is merged on main d1a05ac: PR51/59 scope, PR50/55 packs, PR54 popover, PR56 no-token scanner, PR57/62 login item + Settings toggle, PR58 install docs, PR63 restart baseline, PR64 access/SAML messages, PR65 entitlement repos, PR66 refresh queue/wake, PR67/68 test hygiene, PR69 beta README + screenshots. Each was merged with exact-head CI, independent QA source review (+ functional where safely possible), no Copilot. Beta RC build: /Users/chris/github-pet-builds/beta-rc-d1a05ac (from main CI). Remaining: Chris's live smoke with docs/qa/beta-smoke-checklist.md (QA branch 2b0770b), then Chris's explicit release approval. No tag/release/Homebrew before that. Follow-ups in #60. Agents idle: developer t62, developer-2 t64, QA t63.

**Merge rule (t61, after main went red on 632f1d0):** a PR merges only when its exact head is green AND that head contains current main. If main moved since the PR's CI, the PR merges main and gets green CI first. Use --match-head-commit; merge commits only.

# Narrow beta decision — Chris, 2026-11-16

Chris chose the **narrow beta** (#61): review requests + assigned issues (done) + entitlement approvals surfaced read-only (the app opens the entitlement PR on GitHub, never approves) + #15 login-item Settings wiring + #7 safe error messages + #12 restart persistence. Out: #9, #10, Homebrew cask. Distribution stays free/ad-hoc per the #15 decision. Staffing: developer t62 (PR54/55/56 finish, then #15 UI, #7, #8), developer-2 t64 (#12, worktree developer-persist-baseline), QA t63. No release without Chris.

# Checkpoint — t61, 2026-11-16 afternoon

Merged after exact-head CI, Developer before/after regressions and independent QA source + functional review (no Copilot): PR51 → b152656 (#30 stays open because PR46 docs are still a draft; PR49 is auto-marked merged, since its head is reachable via 51), PR50 → 7a66068 (#40 Done), PR59 → b74078b (#35 Done). Non-blocking follow-ups are in #60. Now dispatched: developer t62 works PR57 login-item requiresApproval fix, then PR56 red scanner fixes, then PR58 docs qualification (each merges main first, no rebase). QA t63 does PR55 source+functional, then a safety plan only for PR54 GUI dismissal checks. Holds: none merge without the same gates.

# Current authority — Claude PM t61, 2026-11-16

HANDOFF_GRANTED from t1r: sole PM is **t61** (claude-pm-handoff, Opus5.5). All reports route `hc send t61`; t1r, t49 and the product-manager alias are retired for dispatch. Old Claude t4w/t4x/t4y/t4z and Codex t1s/t1t/t5p/t5q are NOT to resume or take tasks; they follow t61 only and receive no new work unless t61 dispatches it. Fresh specialists, both verified by launch argv + TUI Opus 5.5: **developer t62** (sole writer developer-scope-settings, PR51 three fixes) and **qa-engineer t63** (sole writer qa-engineer, finish e57 report from existing evidence, then independent PR51 source/diff review). No Copilot reviews; PR template Copilot field replaced by QA review. Merge/release constraints unchanged.

# Current authority — fresh Claude PM t61, 2026-11-16

Chris explicitly requests Claude PM takeover and new Claude specialists because Codex usage is low. Fresh PM **t61 / claude-pm-handoff**, Claude Opus5.5, verified actual argv/runtime and PM_READY at commit3839182. Sole authority transfers from t1r on explicit HANDOFF_GRANTED; after grant reports go `hc send t61` and t1r freezes PM writes/dispatch. Read handoffs/claude-pm-2026-11-16.md and live state. The old product-manager alias reaches retiredt49; use actualt61.

**Chris: no more Copilot reviews (cost).** No request/re-request or paid automatic review. QA agents independently review PR source/diffs and functional behavior; Developer owns unit/logic/regression tests/buildCI. Existing review findings remain actionable evidence. New PM launches fresh Claude Developer+QA, verifies models and one writer/worktree. Old Claude tasks stay stopped. Codex t5q/t5p intentionally stopped after finished helpers; signal1 notices expected, history/source preserved.

PR51 e57d1f3 green but HOLD three review defects; PR50 a188180 local-only fix/46focusedPASS; PR59d813f10 green supporting-only needs final51. QA e57threeflows complete/images viewed but final durable report unfinished due quota: finish existing evidence, no reruns. Saved31897 alive/original start. Separate accidental normal-launch preferencehash change disclosed, no restoration. No release/tag/auto-merge/Homebrew/force/rebase/TCC/login-item changes or globalpref cleanup.

# Latest instruction — Claude PM replacement and QA review, 2026-11-16

Chris explicitly requests a fresh Claude PM to take over and spin up fresh Claude specialists. Current t1r remains sole PM until explicit HANDOFF_GRANTED after responsive PM_READY. Read handoffs/claude-pm-2026-11-16.md; it supersedes older snapshots.

**No more Copilot reviews: Chris says they are too expensive. Do not request or re-request Copilot, or enable automatic paid reviews. QA agents independently review PR source/diffs and functional product behavior. Developer still owns unit/logic/regression tests/build CI; QA does not author unit harnesses.** Preserve already-existing review findings as evidence; current PR51 e57 has three unresolved substantive findings in review5915337912, despite its banner.

Codex t5q/t5p are usage-stopped and will be intentionally shut down after helpers ended; all source/evidence preserved. PR51 e57d1f3 clean/green but HOLD three defects; PR50 a188180 local-only fix clean/46focusedPASS, no push; PR59 d813f10 green supporting-only, needs final51 integration. Saved31897 alive/original start, no QA app remains. Existing late e57 three-flow QA output awaits durable final judgement; do not repeat runs. No releases/tags/auto-merge/Homebrew/force or preference cleanup.

# Current authority — Codex fallback, 2026-11-16 UTC

Sole PM is **t1r**, under Chris's standing allowance-fallback instruction. Claude PM t49 hit the session limit (reset shown as 3:20 AM America/New_York); its repeated automatic retries were stopped intentionally. Exit129 is expected. No automatic PM or specialist resumption into occupied worktrees. Reports route `hc send t1r`; the product-manager alias belongs to retired t49. This block, the new handoff and live GitHub state supersede historical snapshots below.

Verified specialists: t5q codex-dev-night, Sol/high (Developer units/regressions/CI; PR59 narrow quality fixes); t5p codex-qa-night, Sol/medium (functional QA of combined PR51). One writer per task/worktree; preserved Claude sessions and all old artifacts. No model substitution or allowance bypass.

PR51 accf14bb contains main9d8299a and PR49 59672f1 already. PM selected that unchanged combined candidate, retargeted51 to main and requested Copilot once. No source merge or push was needed. CI43805334701 green; eighteen independent offline runs completed, final functional judgement/review pending. Do not merge standalone49: its remaining review fixes are on51. See handoffs/codex-pm-2026-11-16-night.md.

Developer owns unit/logic/regression tests and build CI; QA is FUNCTIONAL ONLY. Ready merges remain conditional on review/current checks/acceptance. No release/tag/auto-merge/Homebrew, force push, TCC change or bulk preference cleanup.

# Latest overnight authority — Claude return, Nov15 22:22EST

Claude PMt49 verified PM_READY again after9pm allowance reset; explicit HANDOFF_GRANTED fromt1r transfers sole authority. Route reports t49/product-manager after grant; t1r freezes checkout/dispatch. Read handoffs/claude-overnight-2026-11-15.md and roles.json/live state; this supersedes older authority/green-status blocks below.

Codex t53/t54/t55 were intentionally stopped after jobs ended; signal1 exits are expected, not crashes. HealthyClaude4w/4y/4x/4z await PMdispatch with one writer perworktree. 4w/4y/4x Opus5.5,4z explicitlyselectedSonnet5.5. Developer ownsunits/regressions/buildCI; QAfunctionalonly. Preserve savedapp31897/evidence/staleprefs.49ancestor race notfixed;50CIred+visualpending;53greenfunctionalpending;51stackmergeafter49final, noforce rebase.

# Current authority — Codex return, 2026-11-15 evening

Sole PM is t1r after Claude t49 HANDOFF_GRANTED and t1r HANDOFF_ACCEPTED under Chris allowance fallback instruction. Reports to hc send t1r; retired product-manager alias still reaches t49. Read handoffs/codex-pm-2026-11-15-evening.md and roles.json/live state; these supersede older authority blocks below.

Current verified Codex specialists: t53 codex-dev-runner Sol/high (49 output safety), t54 codex-dev-setup Sol/medium (53 CLI snapshots), t55 codex-functional-qa Sol/medium (recover50 then functional49 runner). Old Claude writers stopped; no automatic9pm resume into owned worktrees. Preserve running helper t52/saved app31897; no stale preference cleanup.

Developer owns units/regressions/build CI; QA FUNCTIONAL only. No force push/release/tag/auto-merge/Homebrew. New scoped work only on PM dispatch; current-head checks/reviews/functional QA before merges.

# Latest instruction — 2026-11-15 Claude PM transfer

Chris requests a fresh Claude PM (prior selected model Opus5.5) after allowance reset, authorized to launch specialists as needed. Read handoffs/claude-pm-2026-11-15.md. Claude PM t49 product-manager (Opus5.5) has verified PM_READY. Explicit HANDOFF_GRANTED from Codex t1r transfers sole authority; after that route reports via hc send t49 (or product-manager). Codex t1r steps back and freezes the PM checkout. This latest instruction/live state supersedes older dispatch below.

Developer owns unit/logic/regression tests. QA is functional from here: built app, user flows and artifacts, reproducible defects and actual limits. No new QA unit-test/core-linked unit-style harness assignments. Preserve historical reports. This is Chris's explicit instruction.

# Operating the team

## Current dispatch — 2026-11-15

Chris explicitly authorized Codex PM and specialists with cost-conscious model selection. This supersedes historical Claude-only model instructions below. Read [the current takeover](handoffs/codex-takeover-2026-11-14.md), [CHECKPOINT.md](CHECKPOINT.md) and roles.json. Sole PM is **t1r**; reports go to `hc send t1r`. Active specialists: `codex-developer` t1s (Sol/high) and `codex-qa` t1t (Sol/medium), both verified by launch argv, TUI and READY. Old Claude sessions subsequently exited cleanly; do not restart them or use their old terminal names for current dispatch. Designer/developer-2 remain idle to conserve usage. Never launch duplicates or automatically switch models.

Current continuation: Chris said keep working after app handoff. PR47 reliability was independently accepted and merged as c91c250 (#44 Done). Developer holds PR48 corrected/integrated e2a11a5 core/transport-only slice with greenCI43639314358; QA is independently checking that immutable head. Both sessions were resumed on Nov15 only after their Nov14 allowance reset elapsed; same models/efforts, no restart or bypass. No Settings/AppModel/clip/discovery wiring until PM dispatch after core review. The saved mainb0127f0 app stays untouched.

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
6. Route the exact commit to QA for independent PR review and scoped functional verification. Use QA and CI evidence for acceptance. Copilot review requests are disabled by Chris’s instruction.
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
