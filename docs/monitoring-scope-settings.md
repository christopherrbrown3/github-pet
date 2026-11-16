# Monitoring scope: Settings editor (slice B)

Builds on slice A's session/controller (`docs/monitoring-scope-application.md`). Adds the native **Settings › Monitoring scope** section, draft access validation and bounded discovery suggestions. Together with slice A this covers #30's UI. Nothing is merged, released or tagged.

## Behaviour

- The section sits after **Data source** in the existing 520 pt grouped Form. The Form scrolls; the window keeps its minimum height. The list holds at most 10 combined entries, and no list grows the window.
- It shows the account (login is display only; Demo/Simulated are labelled) and the active scope summary with counts. A radio choice offers **Everything accessible** or **Selected organizations and repositories**. Selected mode shows separate Organizations and Repositories lists. Each has editable rows, Remove, and a typed Add field (Return or Add).
- Input is trimmed and deduplicated case-insensitively against both lists. The combined maximum is 10. Malformed input (qualifiers, spaces, quotes, extra `/`, non-ASCII look-alikes, over-length) is rejected inline before it can reach a query. Errors are text labels on the row/field and in accessibility labels/hints. Results are announced with `NSAccessibility` announcements. Messages never echo the input.
- Edits are a draft. **Cancel** restores the active selection. Apply is blocked for an empty or invalid Selected draft, or while the account is unknown. **Apply** for Selected runs one `gh api graphql --hostname github.com` operation: `viewer { id login }` plus per-target `organization(login:)` / `repository(owner:name:)` metadata, with every value passed as a `-f` variable. A per-target `NOT_FOUND`/`FORBIDDEN` (null alias) marks that row *not found or not readable*. A different returned name marks it *renamed*. Any other error, a missing alias, a wrong viewer or a failed gh exit leaves the selection **unverified**: nothing is saved and the active scope and rows are unchanged. A zero-match search is never used as evidence.
- Commit goes only through `AppModel.applyRepositoryScope(scope, identity:, generation:)`. It is never the data-source switch, and incidents are untouched. The reply must still match the draft revision, the identity and the session generation. Edits, Cancel, account/source changes or another Apply discard it (`discardedReplies`).
- **Find suggestions** is explicit; opening or editing Settings never connects. It reads `viewer.organizations` and affiliated `viewer.repositories` (OWNER, COLLABORATOR, ORGANIZATION_MEMBER) with manual cursors: at most 3 pages × 50 per category, one shared 20 s / 2 MiB budget, and the viewer checked against the expected account on every page. A mismatch discards all hints. The status shows *end of this list*, *limit reached; more exist*, *incomplete* or *unavailable* per category. Suggestions only fill the typed field. Apply still validates, and typed entries are always allowed.
- Blocking gh work runs on a Dispatch queue, never on Swift's cooperative pool.
- Demo (Fixtures source) edits the separate `.demo` record and validates offline only, never live.
- A corrupt saved Selected opens as an empty Selected draft. Its configuration error now points to Settings › Monitoring scope. Choosing Everything or a validated selection repairs it.
- Target names appear only inside Settings. Inbox/hover/menu summaries keep counts.

Small additive changes to slice A code: `AppModel` gains `scopeEditor`, the access client and two read-only accessors, and `sync()` calls `scopeEditor.observeActive()`. The Simulated menu gains a sibling menu. `ScopeSimulation.currentAccount` is new. The corrupt-configuration message/quality text now names Settings, and its slice A test was updated to match.

## Offline functional QA

```sh
/path/to/GitHubPet.app/Contents/MacOS/GitHubPet --simulate-monitoring-scope
```

This is the same opt-in, offline, throwaway-defaults launch as slice A. Open Settings › Monitoring scope. The Inbox has a **Simulated Settings checks** menu with these controls: Discovery complete / capped / partial / denied / identityMismatch, Validation normal / network failure, Hold next validation, and Deliver held replies.

Simulated access rule: an owner starting with `demo-` is accessible unless the entry contains `denied`. `demo-renamed` reports a different current name. Anything else is *not found*.

- **Draft/Apply/Cancel:** add `demo-b` and `demo-c/tools`, then Cancel: the lists return to `demo-a` and the Inbox is unchanged. Add them again and Apply: status reads *Monitoring scope applied: Selected · 2 organizations, 1 repository.* The Inbox header shows counts only, and public incidents stay unchanged.
- **Invalid/injection:** type `org:demo is:pr`, `demo/pet repo:x/y`, `a/b/c`, `de mo`. Each is rejected inline and not added. `  Demo-B ` is trimmed; adding `demo-b` again reports a duplicate.
- **Max 10:** add entries until the combined count is 10. The next Add reports the limit.
- **Validation failure keeps active:** add `demo-denied` or `other/pet` and Apply. The row shows the error, nothing is applied and the rows are unchanged. Set Validation: network failure and Apply: *Could not reach GitHub. Nothing was applied.* The draft remains for a retry.
- **Late validation:** choose Hold next validation, then Apply. Switch to Account B: the draft resets to B's selection with a discarded-draft announcement. Deliver held replies: nothing changes, and returning to A shows A's original selection.
- **Discovery:** Find suggestions with each discovery mode: complete (3 orgs, end of list), capped (150, limit reached), partial (100, incomplete), denied (sign-in message, no hints), identityMismatch (all hints discarded). Typed Add still works in every state.
- **Corrupt saved:** in the Simulated scope menu, choose Corrupt saved A and reload. Settings shows an empty Selected draft and the quality text points to Settings. Apply a valid selection or Everything to repair it.
- **Demo isolation:** switch the data source to Fixtures. Settings says Demo, Find suggestions is disabled, and Apply never validates. Return to GitHub CLI: A's selection is intact.

### Scenario runner (no clicks or Screen Recording)

```sh
GitHubPet --simulate-monitoring-scope --qa-scenario <name|path.json> --qa-output <empty dir>
```

Built-in PR B scenarios: `settings-draft-apply-cancel`, `settings-invalid-input`, `settings-max-10`, `settings-discovery-capped`, `settings-discovery-partial`, `settings-discovery-denied`, `settings-discovery-identity-mismatch`, `settings-validation-failure-keeps-active`, `settings-min-size-long-lists`. Each `step-NN-*.json` gains a `settingsScope` record with what the section shows: account, active summary, mode, rows with inline errors, input errors, Apply/Cancel/Find suggestions enabled, blocked reason, status announcement, discovery text, suggestions, discarded replies, launched/received checks and the simulated-check status. `open-scope-settings` writes `-settings.png` (the window at minimum size, Form scrolled to the top) and `-scope-section.png` (the section itself, 520 pt).

Step actions (each calls the method the matching control calls): `settings-mode {mode}`, `settings-add {kind, text}`, `settings-edit {kind, index, text}`, `settings-remove {kind, index}`, `settings-apply`, `settings-cancel`, `settings-find-suggestions`, `settings-use-suggestion {kind, index}`, `discovery-mode {mode}`, `validation-mode {mode}`, `hold-validation`, `open-scope-settings`. `deliver-all` also releases held validations. The runner records state and never judges pass/fail.

## Developer evidence

- `ScopeEditingTests` (core): draft trim/dedupe/limit/injection, access plan/parser/gh exit classification and budget, discovery paging/cursors/caps/partial/identity/malformed/denied/budget.
- `ScopeEditorTests` (app, real AppModel, simulated launch, frozen budget clock, handshake waits): draft/Cancel, validated Apply/announcement/persistence, unavailable/renamed/network failure, empty/invalid/max, late validation versus account switch/edit/Cancel, corrupt repair, demo isolation, discovery states, and hints discarded on account change. The simulated launch is in-memory (`EphemeralDefaults`), so nothing reaches disk.
- Render check adds `settings-scope-long(-dark).png`: a 10-entry draft with inline errors at 520 pt.
- `SettingsScenarioRunnerTests` executes every PR B scenario through the real AppModel and checks its records.
- **Pre-existing leak fixed:** snapshot renders (`--render-snapshots`, including CI render-check) used the real `dev.github-pet.render-snapshots.<pid>` suite, which left an empty plist in `~/Library/Preferences` after each run. They now use the in-memory `EphemeralDefaults` domain, with a regression test.

Manual VoiceOver, keyboard and pointer checks are functional QA evidence; renders do not establish them.
