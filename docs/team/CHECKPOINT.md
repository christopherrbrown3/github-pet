# Team checkpoint — 2026-11-13

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . The project is private and requires owner access. GitHub issue/PR comments and live state supersede this snapshot.

## Sessions

| Role | Terminal | Actual model | Work |
|---|---|---|---|
| product-manager | t1p | claude-opus-5-5 | Chris requested Claude takeover from Codex t8 (gpt-6.1-terra); board, coordination, review and authorized merges |
| developer | t9 | claude-opus-5-5 | PR18 six Copilot findings, then QA defects |
| graphic-designer | t1n | claude-opus-5-5 | Chris requested Claude takeover; #29/badge visual review |
| qa-engineer | t1m | claude-opus-5-5 | Chris requested Claude takeover; independent exact-SHA verification; no CUA tool |

Saved conversations and launch mappings are in roles.json. All resumed specialists responded. Keep dedicated worktrees; inspect live Herdr before recovery.

## Deliverables and remaining work

- PR #18 implementation: current checkpoint SHA 10228d045860d73d33dc919f2df99917594aff0e; CI 43472908487 succeeded, 131 developer tests. Developer reports real-host resizing regressions fixed and compact hover placement. The near-touching badge revision is still pending. Earlier QA at a3d7aa7 found size64 retained a128 panel and badge256 clipped; those are not independently reverified on this head. No current-head full acceptance claim.
- PR #19 artwork/design: checkpoint head 05ea2cde6f6e242be694d6705b6b78836f7d3bb7. Original generated assets are already cherry-picked into PR18. Newer docs specify responsive badges and a finite double-wave; Chris subsequently requested approximately1pt visible-art badge clearance, so another design revision is pending.
- #25 drag/click/persisted origin and #26 fresh Settings geometry passed independent QA on3db865e. These reports remain scoped to their SHAs.
- #27 actual native popover-arrow capture remains blocked. Window bounds and render reports cannot be called native-arrow visual proof.
- #28 remains In Progress; QA source comments6859936842/6859937291 preserve latest interrupted results and CUA native-pipe failure. Preserve the one QA app/worktree; no permission changes or forced cleanup.
- #29 attention animation runtime implementation remains pending.
- #30 repo/org/everything scope selection is Backlog. #11 service incident monitoring remains unimplemented. Current live sources cover review requests and assigned issues; fixtures are the default.
- #15 distribution is free only: Homebrew tap/cask plus GitHub Release app ZIP, ad-hoc signed, no paid Apple Developer account or notarization requirement. Verify/document Gatekeeper first-launch behavior. No release is authorized.

## Merge authorization and constraints

Chris now explicitly authorizes merging ready PRs after Copilot findings are reviewed/handled. Check current immutable head, conflicts, relevant checks and acceptance; do not merge an incomplete application just because it is conflict-free. Releases and auto-merge are not authorized. Native SwiftUI/AppKit, gh-only authenticated access, read-only product and no hardcoded internal repositories remain mandatory. Unknown/stale/partial/error never means empty. Do not bypass model limits or overwrite other worktrees.

## Takeover update

QA and Designer responded from Claude Opus5.5 sessions t1m/t1n with clean dedicated worktrees. Current PR18 head at takeover is f22deaf336c94140e10bcbc207df5649e7b3aee4, CI43487323700 green138tests. #29 double-wave implementation is included; CI has system Reduce Motion enabled, so the positive gesture probe is SKIPPED while suppression is verified. QA independently completed this exact head: build/signing,138 tests, render-check, a positive model-level gesture probe with local system Reduce Motion off and seven focused gesture checks passed; native desktop motion remains unverified because CUA is unavailable. Designer reviewed selected stills/filmstrips; natural motion remains unverified. Developer is implementing immediate cancellation on explicit snooze/quiet changes and system Reduce Motion notifications; clock-driven quiet-hour boundaries remain tick-driven. README PR32/33 are merged. New #29 code needs Copilot review. See handoff for prior exact-SHA evidence and constraints.

## PM takeover

Chris requested a Claude Product Manager. Claude Code t1p (claude-opus-5-5) sent PM_READY, received HANDOFF_GRANTED from Codex PM t8 and accepted it on 2026-11-13. Specialists route reports via `hc send product-manager`; their Herdr parent remains t8, so notifications to the parent do not reach the new PM. Use role names and `hc ls`. At transfer, PR18 head e0789eec8a877bf7b68de7ee6607f2fcf63a4c7b had CI43490177306 green with 143 Developer tests. Developer implements immediate cancellation on snooze, quiet hours and Reduce Motion. QA was verifying it in qa-verify-e0789ee. Developer triaged six new Copilot threads as valid and was dispatched one commit per finding. The gh account-switch finding uses a single request-bound GraphQL query, because identity checks before and after the searches would miss an A->B->A switch. The Designer flagged the mascot's resemblance to GitHub's Octocat for owner review before #15 public distribution. Live motion remains unverified.
