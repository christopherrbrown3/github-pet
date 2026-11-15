# PR48 exact97 scoped errors-member QA — FAIL / HOLD

Head **`97e797a32598dfd02624de35f19cb4af09fe209c`**. Independent bounded normal-import probe confirms the remaining scoped quality gap:

- Full JSON response, verified viewer/two valid source aliases, **`errors:[]`**, zero rows → **complete=true, items0, issues[]**.
- Same fixture with one valid row → **complete=true, items1, issues[]**.
- Absent-errors empty/row positive controls both remain valid/complete.

This is inconsistent with the requested any-present-errors-member policy and the fixed legacy client. Preserve verified rows/account as partial, with a quality issue, when an errors member is present, including empty/malformed shapes. Retain typed rate-limit handling and absent-errors valid controls.

Evidence: scoped-empty-errors-before.log and scripts/qa/pr48-scoped-errors.swift. Compiled directly against the completed/held exact97 core with normal import; source/module hashes rechecked unchanged. No real transport/auth/UI/user-state changes. This is negative-before evidence, not a full matrix or whole-PR acceptance. Four new repository legacy regressions and prior98/18/general passing evidence remain retained.

**All97 links/probes finished and the held build was explicitly released to Developer before mutation.** Existing97 CI/artifact helper is GitHub-only supporting evidence, not acceptance. Await the narrow ScopedGitHub+tests fix, new completed immutable SHA and current CI; rerun only affected scoped quality matrix and reuse unchanged evidence. No UI/scope expansion or broad repeat.
