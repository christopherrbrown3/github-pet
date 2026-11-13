# Team checkpoint — 2026-11-13

Board: https://github.com/users/christopherrbrown3/projects/3/views/1 . It is linked to the public repository but the Project itself is private. Owner login is needed to view it. There are 19 issue items at this checkpoint; counts can change with new defects.

## Sessions and work

| Role | Terminal | Actual model | Current responsibility |
|---|---|---|---|
| product-manager | t8 | gpt-6.1-sol | Coordinate board, review, QA and recovery; originally requested Astra, current model difference disclosed |
| developer | t9 | claude-opus-5-5 | Triage newer Copilot findings and fix confirmed issues locally; keep tested remote SHA stable for QA checkpoint |
| graphic-designer | t1h | gpt-6.1-sol | Preserve exact-SHA retest evidence in PR #19; available for visual defects |
| qa-engineer | t1g | gpt-6-luna | Live native acceptance at 3cf6fa7, short durable checkpoints after each group |

Specialists resumed their original saved conversations following quota reset and each sent a readiness handshake. Herdr shows all four agents in one 2×2 tab. Session IDs are in roles.json; inspect actual live state before reuse.

## Reviewable deliverables

- Implementation PR #18: https://github.com/christopherrbrown3/github-pet/pull/18 . Remote head 3cf6fa7fd95fd6b491802261331ec2bbc8db72aa. CI run 43308089243 matches this SHA and succeeded: 102 developer tests, bundle/signature/asset checks, native offscreen render checks. This is CI evidence, not full independent acceptance.
- Design PR #19: https://github.com/christopherrbrown3/github-pet/pull/19 . Head 7a108969eb449b6896b6b6a3d07780e7662602e4 after evidence recovery. Original generated assets are integrated into PR #18; the latest PR #19 commits only add review evidence. Exact-SHA retest record: https://github.com/christopherrbrown3/github-pet/blob/7a108969eb449b6896b6b6a3d07780e7662602e4/docs/design/reviews/pr18-088b678-3cf6fa7-retests.md .
- Latest independent saved QA checkpoint before restart: https://github.com/christopherrbrown3/github-pet/pull/18#issuecomment-6836094991 at 6f938c0. 101 tests/build/offscreen rendering passed. Live menu-bar and Inbox regression was NOT RUN there.
- Prior QA reports are retained at their old SHAs. They must not be counted as passes for the current head.

## Open acceptance

Issues #20 blank Inbox and #21 partial data remain open/In QA. Issues #22 contrast and #23 label overlap have Designer still-image passes (#22 at 088b678, inherited unchanged; #23 at 3cf6fa7). Both are now published and In QA, not Done. Still-image passes establish no mouse, animation or accessibility behavior.

QA first group: native default Inbox rows and actual MenuBarExtra popover rows; sticky Partial data single-click/checkmark and persistence through refresh/Return/timer. Then pointer transparency/drag/persistence, shared inbox, GitHub links, missing gh/authentication, privacy, reduced motion and event baseline/deduplication/one-shot behavior. Save PASS/FAIL/BLOCKED with exact build and evidence, not inference from counts.

Developer is triaging further Copilot rounds beyond the original 11 findings: snapshot privacy and isolated preferences, account identity baseline resets, partial unread retention, pinned GitHub host, privacy default and accessible mascot press. A finding may already be fixed; validate before editing. Confirmed fixes remain local until QA records a stable current-build checkpoint, then PM coordinates the next exact SHA.

## Constraints

No PR merge, release or auto-merge authorized. Native SwiftUI/AppKit, gh-only authenticated access, read-only product, configurable entitlement repositories, public-safe fixtures. Unknown/stale/partial/error never means empty. Use separate role worktrees and preserve other edits. No usage-limit workarounds.
