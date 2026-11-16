# PR54 #41 popover-dismissal GUI checks: safety plan (no runs)

QA: Claude Opus 5.5 (`claude-opus-5-5`), task H from PM t61, 2026-11-16. This is a plan only: nothing was launched.

**Answer:** these checks **cannot be done safely and automatically under the current rules**. The only safe way is manual, with Chris present, and only after PR54 has merged main. Until then, the gate should be the Developer's real-controller regressions plus a QA source review and an offscreen non-regression run.

## What #41 (c) changes

PR54 head `cf180e21a7ff71381ed8fca1cccce5840818fa2d`; CI 43801775278 succeeded on that exact head. The branch is behind main: its merge base predates PR50, PR51 and PR59.

- **Change:** `MascotWindowController` becomes the `NSPopoverDelegate` of the summary popover. In `popoverDidClose` it forgets only the popover that is current, then clears its inputs and orders out the anchor.
- **What to observe:** after macOS dismisses the hover summary itself (click elsewhere, Esc, Space change), the next model change must not re-show it while the pointer is elsewhere.

## Why fully automated GUI checks are unsafe today

1. **Real input events are needed.** Hover, click-away, Esc and a Space change need real pointer, keyboard or Mission Control events on Chris's live desktop. Synthetic events have two routes, and neither is allowed:
   - `CGEventPost` needs Accessibility permission for the sending process. That is a TCC action, which is prohibited.
   - CUA could do it, but CUA app binding already normal-launched an artifact once (the PR51 incident). Our rule bans CUA or GUI auto-launch.
2. **Observing the result also needs permissions.** `screencapture` needs Screen Recording permission, also TCC, and we must neither check nor change TCC. The app writes no log line when the popover is shown or closed, and the scenario runner has no hover or popover actions. Adding them would be a new hook, which is out of scope.
3. **This branch has no simulation launch mode.** `cf180e2` has no `--simulate-monitoring-scope` (it arrived with PR51 on main). Its windows also autosave frames unconditionally: `WindowPresenter.swift:35` writes `NSWindow Frame GitHubPet.*` into the **real** app domain. The guard was added only on main (`WindowPresenter.swift:38`, `autosavesFrame`). Opening the Inbox or Settings, which a stray click on the mascot does, could change Chris's real preferences. That is the same class of event as the earlier incident.
4. **A Space change disrupts Chris's session.** It moves the whole desktop, including the protected app 31897.

## Recommended path

1. **Now (no GUI):** accept the Developer's three real-controller tests (`MascotWindowLifetimeTests`), which have fail-before evidence in the PR body:
   - `systemDismissedSummaryIsNotReopenedByALaterModelChange` closes the popover the way AppKit does, then injects a row.
   - `replacedSummarysLateCloseKeepsTheCurrentOne` checks the guard against clearing the current popover.
   - `droppedControllerFreesItsPanelAndContainer` checks the retain-cycle fix.

   QA reviews the source and diff. Optionally, run the existing offscreen `--render-snapshots <dir> --fixtures` on the exact-head CI artifact as a hover-placement non-regression; it renders hover probes without real input.
2. **After the Developer merges main into PR54, and only with Chris's explicit go-ahead and presence**, a manual check:
   - **Pre-flight:**
     - Only 31897 is running.
     - Take the hash-only preference snapshot (`scope-artifact-functional.py --snapshot-only`).
     - Put the gh tripwire on PATH.
   - **Launch:**
     - Launch the exact-head CI artifact by its full path, from the terminal only, with `--simulate-monitoring-scope` first. That gives ephemeral defaults and no frame autosave.
     - Record the PID.
   - **Chris does by hand (QA gives instructions, no automation):**
     - **Esc:** hover the mascot until the summary shows, press Esc, move away, then trigger a model change with the existing Simulation menu "Inject row" (a menu-bar click on our own instance). Expect the summary not to reappear.
     - **Click-away:** repeat, closing with a click on the empty desktop, not on the mascot.
     - **Space change:** optional, only if Chris accepts it. Repeat, closing by switching Space.
     - **Observation:** Chris confirms visually. No screen capture unless Chris provides it.
   - **Quit and verify:**
     - Quit the exact PID with `scripts/qa/quit-pid.swift <pid>` (AppKit terminate on that PID only; never a bundle-wide quit).
     - Take the after-snapshot and require hash equality.
     - Confirm 31897 is unchanged.

## Verdict

- **Can it be done safely?** Not autonomously, and not on the current branch.
- **Earliest safe form:** step 2 above, after PR54 merges main, run manually by Chris.
- **What I'd do instead:** the Developer regressions plus QA source review and an offscreen non-regression run are the appropriate gate. I'd treat a manual GUI check as optional confirmation, not a blocker.
