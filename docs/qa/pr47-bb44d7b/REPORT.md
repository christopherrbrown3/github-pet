# PR47 independent exact-head QA — PASS

Head **`bb44d7b47c300793b7a9ab30c73a9844b5f16f82`** (remote rechecked), issue44. CI [43633750212](https://github.com/christopherrbrown3/github-pet/actions/runs/43633750212) SUCCESS; exact-head Copilot5906781203 reports no open code issues. **PASS for the bounded timing-test/snapshot-fixture fix; no reproducible scoped defect found.** Native timing/desktop motion is not signed off.

## Scope and preserved evidence

Inspected all four changed files. Two elapsed-duration assertions use ContinuousClock without relaxing their bounds. Domain Date timestamps remain Date-based. Runtime InboxEngine, ServiceStatusMonitor and AppModel are byte-unchanged from base645950c; only the snapshot renderer adds unchanged fixture refreshes before deliberate injection groups. Renderer entry remains the explicit snapshot hook, not normal live polling.

Reused completed exact-head Developer evidence: two duration tests PASS (slow drip2.023s, descendant pipe4.017s) and four core freshness/recovery tests PASS, including fixed-Date601/1062s regression. Logs copied adjacent and labeled Developer evidence. No broad suite was rerun.

## Independent AppModel/snapshot-order probe — 96 assertions PASS

Fresh detached exact-head source checkout; Developer explicitly held its completed clean bb44d7b build immutable. QA compiled a separate executable using exact core objects, recording and rechecking object hashes. **One disclosed QA-only seam:** in a temporary copy of AppModel, `let clockOffset` becomes `var clockOffset`; all clock methods, state/event logic and engine code are unchanged. The one-line diff is saved in clock-seam.diff. No shared source/build object was modified.

Advanced the existing app-clock offset by **601 and1062 seconds**, without sleeping or changing the system clock. For entitlement, workflow failure, new major incident and new critical incident, exercised both controls:

- Without the new unchanged refresh, injection is silent stale recovery (negative control), though the new row is retained.
- With `refresh(); inject…()` matching the new snapshot ordering, unchanged recovery is silent/fresh and retains identical baseline IDs; exactly one new row/event is then observed.
- Mark seen, replay snapshot and poll unchanged: no unseen event or marker burst returns.

Sixteen short sequences, **96 assertions / zero failures**. Snapshot options disable periodic source polls; fixtures and isolated preferences only; reduced motion set only in each throwaway model. No native render, pointer interaction or saved app launch. The QA clock seam is model-level timing evidence, not an unchanged production-binary or long native-render-gap test.

## Actual CI artifact — PASS

Independently downloaded the actual green run's render-check artifact into a fresh QA directory and inspected its report/log. **278 tests PASS**, render-check all checks PASS. Deliberate inbox injection/replay both retain four rows with attention, major/critical incident counts advance as expected. This artifact validates the normal CI sequence; it does not simulate a >staleAfter rendering delay. Positive gesture execution is explicitly SKIPPED because runner system Reduce Motion is ON, not counted as motion proof. No screenshot sweep or universal build repeated.

Limits: no prolonged native GUI/render-load reproduction, manual desktop motion or system clock change. Existing saved mainb0127f0 app/process/settings untouched. Same Sol/medium t1t session continued; no restart/model change. No production patches, merges, releases or board changes. Exact-head logs/probes saved under docs/qa/pr47-bb44d7b and scripts/qa/pr47-*. PR48 final verification waits for its fixed-head handoff.
