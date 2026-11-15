# PR48 independent exact-head QA checkpoint

Head **`1d5a9115d6ff338a308813cb01e1a2422824e606`**; CI43737962079 SUCCESS. **Legacy L1/L2 positive-after checks PASS; superseded-head supporting evidence only, not final acceptance.** Actual green render artifact/log downloaded after the existing watcher completed; no source/object access was involved.

**Superseded-head hold:** PM requires a test-only legacy-client transport coverage commit (Copilot4579267187) before acceptance. Repository guards must cover legacy incomplete preflight/query output and shared preflight/query bytes/deadline, since AppModel uses that client. Independent legacy adversarial evidence already passes and is retained; it does not replace CI-owned regression coverage. All1d5 object links/probes are finished and the held build was explicitly released to Developer before mutation. Any existing1d5 CI/helper output is supporting evidence only, not final acceptance. Await the new test-only exact SHA/held handoff; verify production-source equality and only the new focused regressions/current CI.

Only two files differ from e2: legacy GhClient/GhGraphQLParser completeness and its regression tests. Scope query/parser, account binding, budget/collector/cancellation implementation, AppModel and accepted47 integration are unchanged. Reuse unaffected e2 independent 36 passing adversarial checks and18 JSON after-fix assertions; the one failed e2 check is rerun here, not waived. Original940 negative-before parser evidence remains preserved.

Clean exact HEAD and completed-held build verified before linking. Core objects/module fingerprinted before/after; unchanged. QA executables use normal import, not @testable or copied implementations.

- Same unchanged real exit7/valid-empty fixture now gives **legacy snapshot([], complete:false)**; response account retained. Scoped client remains incomplete with transport issue. Thus prior L1 behavioral failure is fixed.
- Independent **98 assertions PASS** across nine errors-member shapes × empty/proven rows, no-error controls, exit0/7, parser error-presence flag and downstream InboxEngine quality. Nonempty/malformed/null/empty errors members cannot produce complete/count-known state; proven rows/account remain partial rather than being discarded. Absent errors and successful exit retain valid complete/empty behavior.
- Four real ProcessCommandRunner/fake-gh cases pass: exit7 empty, exit7 with row, exit0+errors, successful valid zero control. No real gh auth, account change, network or user settings operation.

No broad suite/render/universal build or repeated unaffected probes. Supporting e2 CI was green but not acceptance; final result must use new exact-head CI/artifact. No saved-main-app/process changes, UI expansion, merges or releases. Evidence under docs/qa/pr48-1d5a911 and scripts/qa/pr48-quality.*.
