# PR42 independent exact-head integration QA

Head `0f720962d549185c0a04d928c2952ef7e9bc3da0` (remote rechecked). Current CI [43607798711](https://github.com/christopherrbrown3/github-pet/actions/runs/43607798711) **SUCCESS**. **Verdict: PASS for the scoped fixes and integration delta. No remaining reproducible scoped defect. Native popover chrome, manual pointer UX and live desktop motion remain unverified.** This supersedes the FAIL/HOLD report at 94d7d1a for the two fixed cases; it is not a manual desktop sign-off.

QA verified clean HEAD at the exact SHA, then linked its preserved independent Swift probes against Developer's explicitly completed/held exact-head SwiftPM modules/objects. No concurrent build/source mutation; no developer-only report accepted as independent evidence.

- Copilot 4570228227: original transparent/no-candidate probe now returns normally and logs `arrow inf pt` rather than trapping. The same unchanged probe previously exited -5 against original 56b071c source carried into 94d.
- Copilot 4570228252: original native-controller repeated-saved-edge drop and beyond-all-displays fallback now both give panel-inside=true, saved-equals-shown=true. The same unchanged probe previously failed both. Simulated drag window movement/release callbacks, no OS pointer movement; isolated preferences and temporary QA panel cleaned up. This is bounded native controller behavior, not manual desktop/drag usability acceptance.
- Eight additional measured native preview cases PASS: 64 pt compact / 128 pt full, minor baseline / injected critical incident, normal / right edge. Correct separate incident line/tier and AX count, inbox badge stays 3, compact remains two lines; native measured sizes 320×51 / 320×115 pt. Every placement meets target, labels clear, arrow 3.0–6.1 pt from art; all right-edge cases flip left. No exhaustive height/pose sweep.

Ancestry and original 56b071c acceptance are reused from the prior 94d report. 94d is the clean automatic merge of original56b071c + main9a533ec (reconstructed tree equal); b09ac0a and 0f72096 add only narrow diagnostic/drop fixes and their regression/report checks. No unrelated production changes. Original truth-table/negative-overlap proof remains useful, superseded for the two newly found cases by these negative-before/positive-after probes.

## Actual green CI/render artifact: PASS

QA waited on the existing Developer CI watcher t2g (bounded event wait, no duplicate CI polling), then independently downloaded **render-check** from run43607798711 into a fresh directory. The actual report confirms:

- Transparent and no-candidate diagnostic paths complete without crashing.
- First edge drop, repeated drop with unchanged saved settled settings, and beyond-all-displays fallback: panel-inside=true, saved-equals-shown=true, expected-origin=true. The repeated case explicitly confirms saved-before-equals-settled=true, exercising the former removeDuplicates defect.
- All **11 measured hover cases**: zero overlap, labels clear, on screen, meets-target=true and arrow anchor within 12 pt of static art. Content growth repositions right→left with art/labels clear and on screen.
- Incident preview/marker stays separate from inbox count; failure removes marker and reports unavailable, resolution removes marker quietly. These integrate PR36 with PR42's compact/full measured placement.

Actual CI log reports **277 tests PASS**, release build/bundle and render-check PASS. CI checked out synthetic merge `18f9506755dbb614696da28ca96ddf03246300ab`; its GitHub commit tree is `b5c269941c5e54d0b0ec3a36dd000fb0f29df0a2`, independently verified equal to exact-head0f72096's local tree. Thus the CI evidence tests the same content. System Reduce Motion is ON on the runner: positive gesture execution is explicitly SKIPPED, not counted as a motion pass. Prior94d run was cancelled on new push, not represented as a failed validation.

Visually inspected **four actual CI images only**, saved adjacent: 10c major incident hover light/dark, urgent128 right-edge placement, idle64 left-edge compact placement. Incident text, separate item count/Demo label and intended side are visible; constrained long incident names elide. Placement composites explicitly use **window-bounds**, not captured native popover chrome; the blue arrow mark is an anchor illustration. They do not establish the actual drawn arrow or animation quality. Other artifact images were not visually reviewed.

Current-head Copilot review5905170839 reports both original threads resolved and no open issues, with native-GUI evidence limitations noted. QA independently validated the regression paths above rather than relying on that header or Developer's report.

Logs, focused harnesses, four inspected images and actual render report are saved under docs/qa and scripts/qa. No broad local render/full test suite, dense sweep, manual user app interaction, system/permission changes, merge or release. PM owns the merge decision and the outstanding desktop acceptance boundary.
