# GitHub Pet team contract

Product Manager alone assigns work and controls authoritative GitHub Projects status. Role identity is independent of model: product-manager (Astra), developer (Opus 5.5), graphic-designer (Sol 6.1), qa-engineer (Luna). Never silently substitute a model.

- No merges during bootstrap without Chris's explicit authorization. No releases or auto-merge.
- Use a dedicated branch/worktree per role/task. Preserve other worktrees and existing remote changes. No force pushes.
- Native SwiftUI/AppKit macOS app. No Electron or hosted backend.
- Every authenticated GitHub operation uses the locally installed `gh` CLI. App uses safe argument-array subprocesses, never shell interpolation. No separate OAuth, GitHub App authentication, PAT ownership, token reading or storage.
- Read-only product: approval actions open the GitHub page. All entitlement repositories are configurable; never commit internal organization details.
- Unknown, stale, partial and failed source data must never look like an empty inbox. Initial sync establishes a baseline. Animate genuinely new comparable events once; no replay on unchanged polls or reconnect.
- Fixtures precede live integrations. Privacy, reduced motion, quiet hours, snooze and hiding the mascot must not misrepresent source state.
- Developer owns production Swift, tests and build CI. Designer owns `assets/mascots/` and `docs/design/`. QA owns `docs/qa/` and `scripts/qa/`, reviews independently, and sends defects to Developer. PM owns planning, templates and `docs/team/`.
- No additional agents unless PM explicitly assigns them. Report exact commit, PR, validation, limitations and next handoff through Herdr and durable GitHub issue/PR comments.

Read `docs/team/OPERATING.md` for dispatch, status and recovery. Actual board/issue state takes precedence over a stale session snapshot.
