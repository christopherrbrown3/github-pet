# GitHub Pet

A lightweight native macOS companion that surfaces actionable GitHub activity through an optional animated Mona, menu-bar inbox and links to GitHub. Monitoring remains active when the mascot is hidden. No Electron or hosted backend.

## Milestones

M1: fixture prototype with native menu bar, optional transparent draggable character, shared inbox, simulated new entitlement request, one animation per genuinely new event, safe click-to-open GitHub links and graceful missing gh/authentication handling. Build and independently verify before requesting merge approval.

M2: read-only monitoring of configurable Entitlements PR workflows, requested PR reviews, assigned issues, Actions failures, eligible deployment approvals, verified GitHub incidents and authored PRs requiring attention. Only gh handles authenticated access. Preserve source quality and event baselines.

M3: modular mascot packs, launch at login, accessible interaction, privacy, reduced motion, quiet hours, snooze, multi-display positioning and simple installation. Distinguish local unsigned builds from signed/notarized distribution.

## Semantics

Entitlements uses repository PR approvals; configurable repository scope and verified user actionability are necessary. Reference: https://github.blog/news-insights/product-news/introducing-entitlements-githubs-open-source-identity-and-access-management-solution/

Inspect mona-monitor for useful data-quality and animation behavior, not authentication architecture. Committed source inspected at 28e05d8af821abdb6aedf59eff88e18ca95719e1: src/app_state.c, src/github_api.c, src/animation.c and design/docs/animations.md. Preserve distinct unknown/loading/partial/stale/error/empty states, initial baseline, comparable snapshots and stable event IDs. Hardware OAuth and MCU constraints do not carry into this app.

Privacy suppresses sensitive text in character previews and bubbles. Reduced motion uses meaningful static poses. Quiet hours/snooze suppress interruption, not monitoring or inbox truth. Approval buttons open GitHub; the app does not mutate approvals.
