# PR42 integration QA — held for two reproduced defects

Candidate `94d7d1ab4cba4bb3a871c7938ca381e13f839759`. **Verdict: FAIL/HOLD** pending fixes for Copilot 4570228227 and 4570228252; no integration acceptance. This supersedes relying on the earlier 56b071c PASS alone for these newly supplied cases.

## Preserved valid integration evidence

- Exact merge parents: original QA-passed `56b071ca6050f30e95327d460cdd69fed984de2c` and main `9a533ec209eb703a2120a03c44fee6c409da748a`.
- Independent `git merge-tree --write-tree` of those parents yields `ddd6d5e026ccf8b4ac392c9651ce9b3ec1ac9b14`, equal to candidate HEAD tree: clean automatic merge, no manual conflict changes.
- HoverPlacement.swift and MascotWindow.swift are byte-identical to the original 56b071c versions. The main delta supplies confirmed service incident/preview behavior; the PR42 merge retains its placement/settled-origin code, including the two uncovered defects.
- Developer's completed exact-94d build/focused test log reports 25 tests / 7 suites PASS. Reused as developer evidence; QA did not rerun the dense height matrix or unaffected suites. CI43607232615 was still running at last observation; no green artifact acceptance claimed.

## Independent bounded reproductions

Used preserved immutable original-56b071c SwiftPM modules/objects and a small QA executable linked against them. Since the affected hover/window source is identical to 94d, these are valid carried-over defect reproductions. Logs under `../pr42-56b071c/`; probe source `scripts/qa/pr42-edge-cases.swift`.

1. **4570228227: confirmed trap.** An ArtProfile with 256 empty rows produces `arrowGap.isFinite=false`, `meetsTarget=false`. Calling the actual `MascotWindowController.reportIfUnclear` terminates the isolated process with **signal 5** (exit -5); it never returns. No interactive user app or custom pack files were modified.
2. **4570228252: both cases fail.** A native controller with isolated fixture preferences and reduced motion receives simulated drag window movement/release callbacks (no OS pointer movement):
   - Dropping 40% past an already-saved right-edge origin leaves the panel partly offscreen: inside=false, saved-equals-shown=false.
   - Dropping completely beyond every display falls back onscreen, but saved raw origin differs from shown fallback: inside=true, saved-equals-shown=false.
   - Exact sampled coordinates are recorded in drops.log; they depend on display geometry. The QA panel was hidden at completion and the isolated defaults domain removed. No system preference, privacy or permission changes.

## Invalid attempt and next step

The initial attempt to link against Developer's live integration build was invalidated because its SnapshotRenderer object changed during linking as Developer committed/rebuilt. That compile exited 1, no product result is attributed to it. Subsequent probes used the preserved immutable 56b build. Wait for Developer/PM's fixed exact SHA and completed build before linking new-head probes; rerun only these two focused paths and bounded incident-preview integration coverage, then inspect new green CI/render evidence. No broad render/full-suite run was launched against the obsolete candidate. Native popover chrome, pointer usability and motion remain unverified.
