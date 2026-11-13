# Team checkpoint — 2026-11-13

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . The project is private and requires owner access. GitHub issue/PR comments and live state supersede this snapshot.

## Sessions

| Role | Terminal | Actual model | Work |
|---|---|---|---|
| product-manager | t8 | gpt-6.1-sol | Board, coordination, review and authorized merges; original Astra difference disclosed |
| developer | t9 | claude-opus-5-5 | #27 hover / #28 badge fixes, then #29 animation |
| graphic-designer | t1k | gpt-6.1-terra | Chris explicitly selected Terra; compact badge design and visual review |
| qa-engineer | t1g | gpt-6-luna | Independent exact-SHA acceptance; CUA pipe currently blocked |

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
