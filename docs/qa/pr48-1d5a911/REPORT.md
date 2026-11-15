# PR48 independent exact-head QA checkpoint

Head **`1d5a9115d6ff338a308813cb01e1a2422824e606`**; CI43737962079 pending. **Legacy L1/L2 positive-after checks PASS; final acceptance waits current-head green CI/review evidence.**

Only two files differ from e2: legacy GhClient/GhGraphQLParser completeness and its regression tests. Scope query/parser, account binding, budget/collector/cancellation implementation, AppModel and accepted47 integration are unchanged. Reuse unaffected e2 independent 36 passing adversarial checks and18 JSON after-fix assertions; the one failed e2 check is rerun here, not waived. Original940 negative-before parser evidence remains preserved.

Clean exact HEAD and completed-held build verified before linking. Core objects/module fingerprinted before/after; unchanged. QA executables use normal import, not @testable or copied implementations.

- Same unchanged real exit7/valid-empty fixture now gives **legacy snapshot([], complete:false)**; response account retained. Scoped client remains incomplete with transport issue. Thus prior L1 behavioral failure is fixed.
- Independent **98 assertions PASS** across nine errors-member shapes × empty/proven rows, no-error controls, exit0/7, parser error-presence flag and downstream InboxEngine quality. Nonempty/malformed/null/empty errors members cannot produce complete/count-known state; proven rows/account remain partial rather than being discarded. Absent errors and successful exit retain valid complete/empty behavior.
- Four real ProcessCommandRunner/fake-gh cases pass: exit7 empty, exit7 with row, exit0+errors, successful valid zero control. No real gh auth, account change, network or user settings operation.

No broad suite/render/universal build or repeated unaffected probes. Supporting e2 CI was green but not acceptance; final result must use new exact-head CI/artifact. No saved-main-app/process changes, UI expansion, merges or releases. Evidence under docs/qa/pr48-1d5a911 and scripts/qa/pr48-quality.*.
