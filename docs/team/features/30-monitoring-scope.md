# Monitoring scope — issue #30 implementation brief

Status: PM proposal for Developer handoff; no runtime change in this PR. Based on current main645950c, issue#30 and the existing native Settings/Inbox implementation. Visitor mode: Operate. Preserve the incumbent grouped SwiftUI Form, system typography, controls, privacy and quiet-motion behavior. No new visual identity or mascot assets.

## Job and result

Let a signed-in GitHub user restrict repository-based monitoring to the work they care about, without interpreting missing access or incomplete results as an empty inbox. Current live categories are requested reviews and assigned issues. The scope contract must also serve future repository-based categories; this brief does not implement those additional sources. Public GitHub service incidents remain global and separate.

Offer **Everything accessible** and **Selected organizations and repositories**. The latter includes organization-only, repository-only and mixed selections. Membership is a union; an item matching both an organization and an explicit repository appears once by stable item ID. “Everything” means no extra organization/repository restriction on supported actionable sources, not all activity or proof that every accessible repository was enumerated.

Default existing installations to Everything. Keep fixtures the default data source and label fixture scope as demo-only. Do not connect live merely because a user opens or edits Settings.

## Settings interaction

Add a Monitoring scope section adjacent to Data source inside the existing scrollable Form. Retain the usable 520pt width/minimum-height behavior; do not grow a list beyond the available window or recreate the title-bar-only Settings bug.

Show the active account and active scope summary, followed by a standard native scope choice. For selected mode, show distinct Organizations and Repositories lists, each with Add, editable input and Remove. Repository input is owner/name; organization input is its login. Support asynchronous discovery/validation through installed gh; matching typed inputs remain possible when discovery is capped or incomplete. The implementation must bound discovery and surface its completion state, not present the first page as the complete set.

Keep edits in a draft until Apply. Cancel restores the active selection. Deduplicate entries case-insensitively and trim harmless surrounding whitespace before validation. Reject malformed target input rather than letting it inject query qualifiers. Use inline, keyboard-accessible row validation and descriptive labels; no custom popup/control vocabulary. Announce validation and Apply results accessibly. Bound long lists and long account/target names without hiding their full accessible text.

Selected mode requires at least one target; an empty draft cannot Apply. A saved selection that becomes invalid, unavailable or corrupt must retain an explicit configuration/error state, never silently broaden to Everything or report a verified empty inbox. A network failure while editing leaves the active selection intact. If an already-active target loses access, its missing data remains visible in source quality until removed or verified again.

The active scope is always visible in the Inbox header and Settings. Outside Settings, privacy mode shows a generic summary such as “Selected scope · 2 organizations, 3 repositories”; it must not reveal configured names in previews, bubbles, logs or screenshots. Explicitly opening Settings permits viewing/editing the configured target names, consistent with user-controlled configuration. No committed internal identifiers.

## Account and polling behavior

PM default while the optional user preference question remains unanswered: remember selections separately per GitHub host/account. This is a stated implementation assumption, open to user correction. First use of an account starts with Everything and a silent baseline; returning to an account restores its own selection. Do not reuse one account's validation/discovery result for another account. Never show the former account's inbox or selection as the new account's verified data.

Apply scope atomically: invalidate in-flight repository fetches/discovery, clear obsolete repository rows/counts/unseen state and queued repository attention, enter loading for the new scope and seed its first valid snapshot silently. Old-scope replies cannot repopulate the current inbox. A failed/partial first snapshot cannot later replay old items as new. Undoing a scope change is another baseline, not an event replay. Scope changes must not reset, suppress or replay the unrelated public service-incident monitor.

Preserve the existing request-bound account identity guarantee. A separate identity check before/after a search cannot establish identity across an A→B→A account switch. Developer must document how all scope validation/results used in a poll belong to the reported account, including any multi-request path; stale or unverified ownership cannot be presented as current success. Prefer the existing single request for viewer identity and related results where practical. All authenticated operations use gh with safe argument arrays; no token reading, storage or separate auth.

## Source quality and bounded work

Verify explicit targets are accessible using gh metadata, not merely a zero-match search. Distinguish invalid/unavailable targets, discovery incomplete, source result capped, partial response, rate limit, offline, signed out and stale retained results. It is acceptable to have no actionable rows in a valid target; that differs from failing to verify the target.

All included targets must participate in complete-source claims. Do not silently drop an inaccessible target or show a complete empty inbox after processing only successful targets. Partial success may retain proven rows with an incomplete count. Every request/pagination path must have documented time/output/page/target bounds and a visible incomplete state when reached. Establish concrete implementation bounds in Developer's plan before coding; bounds are product-visible constraints, not permission to truncate silently. Do not assume repeated org/repo search qualifiers implement a union: demonstrate semantics with fixtures and official query documentation before relying on them. Prefer server-side scoped queries over globally capped search followed by local filtering, which can miss all selected work.

## Acceptance and review

Fixtures precede live integration. Use invented organization/repository names and an injectable gh runner. Focused tests must cover:

- Existing settings migrate to Everything; selected organizations/repositories/mixed union; duplicate inclusions produce one stable item/event; invalid/corrupt/empty selected configuration never silently broadens.
- Discovery pagination and bounds, inaccessible/removed targets, zero actionable items in a verified accessible target, partial/GraphQL errors, capped matches, rate limits, stale and signed-out results.
- Apply while a request is running, rapid Apply changes, old response arrives last, account change during validation/search and returning to a prior account.
- Initial baseline, scope changes, recovery and unchanged polls stay silent; a genuinely new event in a comparable scoped snapshot animates once. Global service incidents remain intact.
- Native settings minimum usable size, scrolling with long lists, keyboard/VoiceOver labels, Apply/Cancel and inline error states, privacy-safe Inbox summary. Existing mascot, hover, drag, reduced motion, quiet hours and snooze behavior retained.

Developer owns production Swift/tests/build CI and supplies exact SHA, focused checks and a PR. Designer can review the bounded Settings/Inbox change if needed; do not launch one just to restate native control guidance. QA reviews independently when quota is available, using the current immutable head and actual artifacts where appropriate. No merge until review/CI/QA gates pass; no release/tag/Homebrew publication. The saved mainb0127f0 app remains an immutable earlier verified artifact.

## Handoff sequence

1. Finish the narrow #44 reliability PR separately; do not mix its test-clock fix into this feature.
2. Developer returns a short implementation plan resolving bounded query union, accessible-target validation and request-bound account identity before production edits for #30.
3. PM records the chosen limits and handles any genuinely open product decision; record any answer to the optional account-persistence question; otherwise use the stated PM default above.
4. Implement fixtures/core/settings within the dedicated #30 branch/worktree, then independent current-head QA. Stage reviewable work while QA is quota-stopped; do not restart/switch agents to bypass allowance.
