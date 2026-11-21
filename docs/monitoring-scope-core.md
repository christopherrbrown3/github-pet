# Monitoring scope core (first slice, #30)

This is an opt-in core API. Settings, AppModel, attention queues and discovery/live UI wiring
are intentionally not part of this slice. The scoped client (`ScopedGhClient`) keeps the Everything
query and result contract; its transport enforces the shared request/output budget. (The earlier
`GhClient` was removed in #60; failure and sign-in classification lives in `GhFailure`.)

## Scope and account ownership

`MonitoringTarget` validates and normalizes organization logins or owner/name repositories.
Normalized components cannot contain whitespace/query qualifiers, GraphQL syntax, URLs or extra path components.
`MonitoringScope` is either Everything or 1–10 distinct selected targets. Its decoding validates
the same invariants; empty/corrupt selected payloads cannot become Everything.

`ScopeSelectionStore` keeps separate records for Demo and each github.com/viewer-node-ID pair.
Login is display metadata, not the persistence key. Missing legacy/new-account records start at
Everything; present-but-invalid records return `corruptConfiguration`. Records over 16 KiB are
rejected before decoding (valid ten-target payloads fit comfortably). No target validation or
network request is triggered by storage or the offline `ScopedFixtureSource`.

`ScopeQueryPlan` puts viewer ID/login, every explicit target's metadata and every inclusion's
review/assigned searches into **one** GraphQL operation. Each search has one validated org/repo
qualifier, supplied as a GraphQL variable through argv. Union happens by stable item ID after
server-side target filtering, never by filtering a globally capped result. The API requires an
expected account for selected mode. A response belonging to another viewer identifies that
viewer but discards all submitted-scope rows/validation; a later application slice must restore
that account's selection and refetch rather than relabel the old selection.

## Completeness

There are at most 20 search aliases × 30 rows (600 raw candidates) before union. Everything
uses two unrestricted actionable-source aliases. Metadata accessibility is separate from a
zero-row search; public organization metadata does not require organization membership.
Missing/invalid metadata, missing aliases, invalid rows/links, wrong target membership,
GraphQL errors, result counts beyond returned nodes, or `hasNextPage` prevent a complete claim.
Proven rows can survive as partial results; no verified sources means failure. Typed issues
distinguish identity mismatch, target/source problems, caps, signed-out, rate-limit, transport,
deadline, overflow and incomplete collection. Raw server error messages/target names are not
used as diagnostic issue strings.

No source pagination is implemented in v1. Discovery is deferred to a later slice: the approved
future policy is suggestions only, 3 × 50 per category, 20 seconds total and the same aggregate
2 MiB collection bound, with visible incomplete
state and typed inputs still validatable. Exhausting membership/affiliation suggestions will
never mean that every readable public organization/repository was enumerated.

## Transport budget and cleanup

One `CommandBudget` starts before planning/preflight and spans auth preflight, GraphQL, both
pipe collectors and response parsing. `ContinuousClock` supplies the total deadline (at most
20 seconds). Each subsequent command receives only remaining time; the preflight cannot start
a second fresh 20-second allowance. Task cancellation is checked before launch and at most
50 ms apart while waiting for the direct child.

The stdout and stderr collectors atomically reserve from the **same 2 MiB budget before
appending each chunk**, across both commands. A crossing retains none of that chunk, cancels
the read and wakes the runner to terminate its child with typed `outputLimitExceeded`.
The byte limit is retained raw output, not a claim about total Swift/Foundation memory;
nonblocking reads use two temporary buffers of at most 64 KiB each. A post-exit size check is
not the production enforcement mechanism.

On normal child exit, both pipes share at most 2 seconds to drain, within the active deadline.
A descendant holding a pipe cannot cause sequential unbounded waits. Kept bytes are returned
with `outputComplete=false` if EOF was not reached; both gh clients reject such output rather
than parsing an apparently valid prefix as success. On error/cancellation, one shared cleanup
grace of at most **2 additional seconds** covers collector cancellation and direct-child SIGTERM;
the direct child is SIGKILLed if still running. No unrelated process or process group is killed.
No wait on EOF or termination is unbounded. As with any synchronous OS API, process launch and
thread scheduling are not hard realtime, but an exhausted deadline can never return success.

Injected in-memory `CommandRunner` fixtures remain source-compatible through a default budget
method that accounts for returned bytes and elapsed time. A custom real-I/O runner must override
that requirement to enforce collection-time limits; the shipped `ProcessCommandRunner` does.
The thread-safe `reserve` and `check` methods are public for external runner implementations.
`scripts/test-public-budget.sh` compiles a standalone normal-import client and exercises the
shared budget across stdout/stderr and successive commands, atomic reservations and typed errors.
It is a separate compiler invocation, so an unrelated test file's `@testable` import cannot
accidentally grant this client internal access.

## Review boundary

Focused tests cover input/decoded injection attempts, migration/corruption and Demo isolation,
account mismatch/return, metadata-vs-empty, overlap deduplication/once-only events, malformed
and capped responses, real chatty stdout/stderr, valid JSON followed by overflow, shared
preflight/request budgets, cancellation and descendant pipes. Existing gh/descriptor/timeout
regressions must also pass. No real authenticated fetch or user preference change is needed.
Independent QA is required on the final immutable head; this draft is not merge-ready.

### Cancellation regression calibration (PR48 rework)

The original `Task.sleep(100ms)` canceller did not prove that cancellation preceded the command
deadline. A controlled old-build executor-occupancy reproduction returned `timedOut` with the
deadline already expired before cancellation was requested. This establishes a fixture ordering
failure mode matching CI, not a traced proof of CI's precise scheduler history.

The replacement checks keep the original 10-second command deadline. Prelaunch cancellation
uses a launch gate and proves no child marker is written. In-flight cancellation receives the
child's PID through a bounded FIFO handshake and calls `task.cancel()` from an independent GCD
queue. It requires remaining active budget, `.cancelled` (never `.timedOut`), the child gone/reaped
and an unrelated test-owned process still running. These checks passed against unchanged old
production transport; no production cancellation defect was observed or patched.

### Identifier validation evidence (PR48 rework)

Old940 native-string constructors rejected embedded-owner/account-ID LF, CR, CRLF, NEL, LS
and PS locally. That raw target example was **not** reproduced here. The original full JSON
response path did accept suffixed metadata IDs and fresh Everything viewer IDs; rows were rejected
and selected expected-account mismatch still discarded all rows. Independent negative-before
evidence is [QA's calibrated report](https://github.com/christopherrbrown3/github-pet/pull/48#issuecomment-6883863530).
No representation mechanism or exploit is claimed beyond these observed paths.

Full-input ASCII byte validation now covers target components and all protocol IDs, independent
of regex behavior across runtimes/string entry points. Surrounding user-input trimming remains
intentional; IDs received from the protocol are never trimmed. Regressions pass the six suffixes
through JSONSerialization and the actual parser: invalid Everything viewer IDs fail, malformed
metadata is incomplete/failure, rows remain rejected. Raw and decoded configuration tests retain
the intended whitespace/case normalization and reject embedded separators.
