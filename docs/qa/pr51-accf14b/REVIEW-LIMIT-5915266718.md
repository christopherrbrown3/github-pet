# Later review limit on accf scoped functional evidence

Root reports combined Copilot review5915266718 blocks overall acceptance: cancelled discovery completions across A→B→A / CLI→Fixtures→CLI can overwrite a newer request; nonzero gh exit with parseable data can incorrectly report exhausted/capped categories.

The existing accf14bb18-run functional PASS remains valid only for the exercised flows. It does not cover these review findings and is not sufficient for overall PR51 acceptance. Developer owns the two narrow fixes/regressions/current CI. No new51launch/probe/CI-review polling by QA. Preserve and reuse unaffected evidence; affected new-head checks await exact green candidate handoff and bounded PM dispatch.
