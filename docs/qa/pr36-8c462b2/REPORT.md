# PR36 independent exact-head QA

2026-11-14 · Codex GPT-6.1 Sol / medium · terminal t1t.

**Head:** `8c462b2673af0b6cafae7018d3e132f0b906d2d8` (remote rechecked).
**Verdict: PASS for functional acceptance and bounded still review. Live desktop motion: BLOCKED / unverified.** No reproducible product defect found in this scope. This is not motion sign-off.

## Checks

- CI [43579009400](https://github.com/christopherrbrown3/github-pet/actions/runs/43579009400): SUCCESS, 274 tests. Reused preserved exact-head debug build and release/ad-hoc-signed app build; both exit 0.
- Independent harness compiles the unchanged exact-head AppModel and LaunchOptions against that checkout's core objects: **55 assertions, zero failures**. Fixtures, isolated defaults suite, no periodic source polls, no network. System Reduce Motion observed OFF; no system preferences changed.
- Focused existing regressions: **10 tests / 6 suites PASS**, including 13 malformed-payload parameter cases and canonical design JSON equality. The previously failing pipe deadline test passed in 4.020 s.
- Preserved local full-suite evidence is **not a clean pass**: 274 tests with one failure, pipe deadline measured 386.4 s wall time despite a 4.061 s reported test duration. The targeted rerun passes; cause of the old wall-clock jump is unconfirmed. CI is independently green. No full rerun was needed.
- Preserved render-check exited 1 with no report; partial PNGs are not a completed render-check. Replaced only missing still coverage with a bounded 9-image probe, all rendered and visually inspected: 64/128/256 pt, critical static light/dark, major at 0.05 s light. Native marker/art/labels, 2×, fixed urgent pose and 99+ badge; transparent background. No dense sweep.

## Four Copilot fixes

| Thread | Result and independent evidence |
|---|---|
| 4568322240 | PASS: ASCII bytes only. Combining accent, keycap, fullwidth, zero-width, uppercase and traversal IDs rejected; decoder/link regressions pass. |
| 4568322323 | PASS: snapshot larger than tracker memory. Independent capacity 1 / four incidents stays silent on repeated polls; major and critical each announced once; developer capacity-2 regression also passes. |
| 4570253363 | PASS: live AppModel failure/stale/resolve clears markerBurst immediately; quick recovery/reopen stays static; unchanged fresh polls preserve current burst. |
| 4570253395 | PASS: baseline reset during a positive burst clears it and unseen incidents; reseeded marker remains static. |

## Simulator and suppression

PASS: initial minor baseline silent; new minor event starts burst; minor→major→critical creates a distinct burst per tier; unchanged/repeated critical, de-escalation and re-reaching critical do not restart it. Maintenance is ignored. Resolve/reopen, disconnect/reconnect and stale/error recovery remain silent. Service-only failure and staleness preserve last-known incident rows and the inbox's fresh state, hide the marker and never claim verified empty. Badge remains inbox-only.

PASS: app Reduce Motion, current quiet window and snooze each cancel a positively started burst immediately, retain fresh monitoring/static marker, suppress new bursts and never replay after lifting suppression. The harness checks model state and phase, not desktop playback. System Reduce Motion notification wiring is source-reviewed; the actual OS setting was not toggled.

## Stills and specification

PASS in the nine inspected samples: siren/flames/smoke sit behind art and below both labels; 64 pt flames reach the gutters without the previous art-edge hard cut; major fade is translucent; light/dark smoke remains visible. Drawing and transcribed spec source have no delta from designer-approved `84a0e30`; canonical JSON equality passes at the final head. The new harness freezes art using only its isolated model setting and passes an explicit burst phase to the real marker view.

Scope limits: no new exhaustive pixel-overlap sweep, no full render-check pass, no interactive desktop burst/flicker/smoke/settle check, native popover chrome or VoiceOver session. Nine stills and model assertions cannot establish natural desktop motion. Prior design still approval remains supporting evidence, not motion evidence.

## Reproduction and preservation

Run `python3 scripts/qa/run-pr36-focused.py`, with `test` or `stills` for those groups. Commands have 100 s compile / 75 s targeted tests / 30 s model / 45 s still limits and use background Herdr terminals. Exact-head checkout must already be built; runner rejects any other SHA. Scripts only write QA artifacts and an isolated temporary preferences domain; implementation checkout is unchanged. Prior worktrees/processes were preserved; no pre-existing QA app/build was running. Logs and nine PNGs are adjacent to this report. Prior original evidence is preserved under `/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/75c23127-a4b1-4819-bc22-3f78b1b19d9e/scratchpad/8c4/`.
