# PR43 independent exact-head QA checkpoint

Head `f1cfada8aeb28588e86952d39496f0cfeee03c34`; CI [43606856503](https://github.com/christopherrbrown3/github-pet/actions/runs/43606856503) pending.

**D2 fixed: PASS. Overall acceptance pending actual green CI artifact verification.**

Delta from `f54d5a6` is limited to `scripts/intel-smoke.sh` and focused tests in `scripts/test-packaging.sh`. No app, workflow, packaging or install-doc changes. Parent exact-head artifact evidence is retained in `../pr43-f54d5a6/REPORT.md`.

Independent negative probe rerun against the unchanged exact-head smoke script: a fixture child writes a valid baseline report, then exits 86; script now exits **86** and diagnoses the failure. Child exit 0 still gives smoke exit **0**. Before the fix the same probe returned [0,0]; now [0,86]. This is isolated process/report handling via local architecture stubs, not actual Intel or Rosetta execution. All eight developer focused regressions independently rerun PASS (two child-status cases, six full/depth-1/depth-2 packaging guards). No app build or broad test sweep.

Next: use Developer's existing bounded CI watcher t24, then download the actual green artifact into a fresh QA directory. Expect signed source revision f1cfada8aeb28588e86952d39496f0cfeee03c34, full-history build 52, matching checksum, strict signature, universal slices and unchanged pack bytes. No final merge-ready verdict yet. Clean-Mac browser-quarantined first launch and physical Intel remain unverified.
