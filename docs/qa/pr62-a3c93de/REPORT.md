# PR62 a3c93de QA: "Open at login" toggle (#15)

**Source review PASS and offscreen Settings render PASS.** No real login item was read through a toggle, registered or unregistered.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task M from PM t61, 2026-11-16.

- **CI:** 43895839559 completed SUCCESS on the exact head `a3c93debabf963ee6f9d10dafb99384de0f9225c` (a single commit on main 5cf5185).
- **Source:**
  - **No backend outside normal launches:** `AppModel` creates `SystemLoginItemBackend` only when `normalLaunch` holds, meaning no `--simulate-monitoring-scope`, no snapshot directory, no QA scenario and no `--defaults-suite`. Otherwise the backend is `nil`. With `nil`, `LoginItemSettings.refresh/setEnabled` return immediately, the toggle is disabled, and the row says "Not available in this launch (simulated, snapshot or test). Nothing was changed."
  - **Reads vs writes:** status is read only when the section appears or the app becomes active. `setEnabled`, the only path that changes anything, runs only from the toggle's binding setter, which fires on a user flip.
  - **Honest text:** "Checking with macOS…" until the first read (toggle disabled); then On, Off., "Pending approval. Allow GitHub Pet in … Login Items", or "Unavailable. … Move it to Applications".
  - **Failures:** fixed text ("macOS didn't turn on/off open at login.") plus the re-read status. The system error string is never shown, and the message clears when the system status changes.
  - **Pending state:** pending counts as registered, so the toggle shows on, while the text says it is pending.
  - **Docs:** uninstall step 4 in `docs/install.md` says to turn the option off in Settings → Startup or in Login Items first, and to check Login Items if the app was already deleted. It notes the feature is unverified on a real ad-hoc-signed Mac.
- **Tests and evidence:** the tests cover the read-only refresh, pending, a refused change clearing when the system changes, not-found, simulated and custom-defaults launches having no backend, and backend injection. Developer evidence `/Users/chris/github-pet-builds/issue15-ui-a3c93de-developer-evidence` shows 6/6 after and a CI-style full run of 458 tests passing. There is no fail-before because this is a new feature.
- **LOW-1:** snapshot and QA-scenario launches aren't asserted in `nonNormalLaunchesHaveNoBackendAndChangeNothing`. They are covered by the `normalLaunch` expression, and functionally below for snapshot.
- **INFO:** dev-only flags without `--defaults-suite` (`--fixtures`, `--placeholder`, `--clock-offset`, `--inject-event-after`) still count as normal launches, so they read real status. That is read-only.
- **INFO:** uninstall step 4 says "before step 2", but it is numbered after it. Consider moving it up.

## Offscreen render (exact-head artifact)

- **Artifact:** `GitHubPet-app` from CI 43895839559. ZIP SHA256 `f64a93fce4621aba2ff4df122a6d47c054f63a854803fcf8c451447fc8dd816a` matches the sidecar. The Info.plist revision equals a3c93de (build 150), and strict codesign passes.
- **Launch:** one `--render-snapshots <fresh dir> --fixtures` launch with the bundled pack, PID 72891, exit 0. A snapshot launch has no login-item backend, so no SMAppService call is possible.
- **Settings PNG (viewed):** the **Startup** section shows "Open at login", toggle **disabled/off**, with the text "Not available in this launch (simulated, snapshot or test). Nothing was changed."
- **Safety:** gh tripwire 0, no preference domains or files changed, protected PID 31897 unchanged.
- **Unrelated process:** during the run, PID 73440 appeared. It was the Developer's own `scripts/readme-screenshots.sh` offscreen render, running from `developer-beta-readme` with throwaway preferences. QA did not touch it.
- **Not covered:** live On, Pending and Unavailable states, which would need a normal launch and SMAppService. They need Chris's consent and a manual check.

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, and `settings-render/{launch.json, stderr.bin, completion.json, before.json, after.json, snapshots/settings.png}`. The helper is `scripts/qa/pr62-a3c93de-settings-render.py`.
