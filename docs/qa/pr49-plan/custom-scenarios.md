# PR49 functional QA: custom scenario ideas (draft before dispatch)

Status: prepared before the scenario runner exists. Scenario syntax gets adapted to the runner's actual JSON schema once the exact head is dispatched. Every verdict comes from QA reading the per-step JSON and viewing the PNGs against `docs/monitoring-scope-application.md`. A runner "pass" field is never accepted as evidence.

## Runner trust checks (run first)

- R1: normal launch (no flags) and `--qa-scenario` without `--simulate-monitoring-scope` must be refused or ignored: no output written, no simulated controls, no scenario executed.
- R2: an unknown scenario name, malformed JSON or an unknown step must fail loudly with a non-zero exit, never a partial "success".
- R3: `--qa-output` cases: nonexistent dir, existing non-empty dir, path pointing into a real prefs/app location, and a relative path. The runner must not overwrite unrelated files.
- R4: cross-check each step's PNG against its JSON (row count, unseen marker, error/loading text, scope header). Any disagreement is a defect in itself.
- R5: run the same scenario twice. The visible state must be deterministic apart from random domain names and timestamps.
- R6: isolation, checked outside the runner: no `gh` children (pgrep), no sockets (lsof -i), only `dev.github-pet.scope-simulation.*` created and then removed after a normal quit, real `defaults` domain byte-identical before and after, saved b0127f0 app untouched.

## Named spec scenarios

Restore-before-display, A→B→A, late reply after Apply, corrupt saved Selected, partial→recovery/new-once, incidents preserved, privacy/source change. Each is checked at every step, not only at the end. Example: `demo-outside/pet` must be absent from every intermediate state.

## Adversarial orderings

- A1 Two held replies, delivered in reverse order (newest first, then oldest) after two Applies (Everything, then Selected). Final state must match the last Apply and discarded must equal 2.
- A2 Hold, switch A→B, deliver held reply: A's rows must never appear under B, and nothing alerts.
- A3 A→B→A with a reply held across both switches: A's stale pre-switch reply must still be discarded (generation guard, not just account equality).
- A4 Corrupt saved A, then switch to B (healthy), then back to A. A stays a configuration error and B is not contaminated. Repair while on B, then return to A: silent.
- A5 Partial replies plus Apply mid-partial, then recovery: no gesture at any step. The next inject alerts exactly once.
- A6 Apply the same scope twice in a row: no duplicate baseline alert and no request storm (request count increases by a bounded amount).
- A7 Inject a row while a reply is held, then Refresh twice: one alert total.
- A8 Incident injected, then corrupt-and-reload: the incident stays visible next to the repository configuration error, and the error is not masked as healthy.
- A9 Unknown-viewer reload that returns viewer B (identity churn): B's own selection is restored, A's rows are discarded, and a second churn gives an explicit failure, never Everything.
- A10 Hold a reply past the 20-second budget, then deliver: explicit failure/timeout state, not empty, and the late reply is discarded.
- A11 Fixtures→GitHub CLI→Fixtures with a held reply delivered at each stage: Demo scope and GitHub CLI scope never cross over.
- A12 Privacy on and off across all of the above: the scope header never contains target or account names (string search in JSON and visual check of PNGs).
- A13 Quit mid-scenario with replies held: the domain is cleaned up, no crash, and no late callback recreates the domain (check `defaults domains` after exit).

## Explicit limits

No real pointer clicks, VoiceOver, live motion/animation timing, menu-bar interaction or Screen Recording. Self-rendered PNGs show the app's own view hierarchy, not the composited desktop.
