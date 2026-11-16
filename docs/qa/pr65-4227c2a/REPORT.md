# PR65 4227c2a QA: entitlement repositories (#8)

**Source review PASS.** The offscreen render confirms that Settings still shows **Startup** after the merge. The renderer does not capture the bottom of Settings, so the new **Entitlement approvals** section is verified from source only.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task Q from PM t61, 2026-11-16.

- **Head and CI:** `4227c2a18f6b8fd3d01eab81e29fa852cdd6becd` contains current main dcb0fc2. CI 43935271864 completed SUCCESS on the exact head.
- **Merge:** `4227c2a` (parents 18fa266 and dcb0fc2) is identical to an automatic merge-tree (`e201904…`).
- **Changes against main:** `AppModel.swift`, `SettingsView.swift`, `EntitlementRepositories.swift` (new), `Settings.swift`, and two test files.

## Source review

- **Validated local list:** `EntitlementRepositories.key` uses `MonitoringTarget(repository:)`, the same validator as the scope editor, and stores lowercased `owner/name`. `add` rejects invalid entries, duplicates and anything over **20** with fixed messages. When loading, `normalized` drops invalid entries, de-duplicates in order and caps at 20.
- **Persistence:** stored only in `PetSettings` (the local defaults). Older settings without the key decode to `[]` through `decodeIfPresent ?? []`.
- **Display-time classification only:**
  - `AppModel.sync` maps `engine.items` through `classified`, and events are reclassified only when they are queued as clips.
  - The engine, item IDs, unseen tracking and the persisted baseline keep the source's `.reviewRequest`, so nothing is re-announced and changing the list doesn't look new.
  - Changing the list calls `sync` straight away.
- **Same link, nothing approved:** `classify` changes only `kind`; the ID, URL, repository and title are untouched. No new search, API call or mutation is involved, and opening a row still opens the same PR.
- **Severity unchanged:** `.entitlement` has the same severity as `.reviewRequest` (`actionable`), so mood and alerts don't change.
- **Fixtures:** `FixtureSimulator` is unchanged; its own entitlement fixtures are still injected as before.
- **Settings after the merge:** `LoginItemSection` ("Startup") comes from main and is kept. `EntitlementRepositoriesSection` is added after Monitoring scope, with a key icon per row, Remove, Add, the fixed problem text, and an explanation that the list is local only and nothing is ever approved.
- **INFO:** a reclassified review request reads "Entitlement update" (the existing `.entitlement` label), while Settings calls these "entitlement approvals". Consider "Entitlement approval" for consistency.
- **INFO:** with privacy mode on, rows still reveal that an item comes from a configured entitlement repository, through the kind label. That is consistent with the generic labels, and no name is shown.

## Offscreen render (exact-head artifact)

- **Artifact:** ZIP SHA256 `ddd92a2c26826cca8a2111d9b94c1d97682edeee748736c0a61763f275fcfb08` matches the sidecar. The Info.plist revision equals 4227c2a (build 183), and strict codesign passes.
- **Launch:** one `--render-snapshots <dir> --fixtures` launch, PID 4668, exit 0. gh tripwire 0, no preference domains or files changed, protected PID 31897 unchanged.
- **`settings.png` (viewed):** Mascot, **Startup** ("Open at login", disabled, "Not available in this launch…"), Privacy and motion, and Snooze and quiet hours.
- **`settings-scope-long.png` (viewed):** the Monitoring scope section.
- **Not shown:** the Entitlement approvals section, which sits below both captures. Snapshot launches also reset settings, and neither the QA runner nor the renderer can set the entitlement list, so **a review-request row classified as an entitlement can't be shown without a new hook**. The Developer's classification tests cover it.

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, and `settings-render/{launch.json, stderr.bin, completion.json, before.json, after.json, snapshots/settings.png, snapshots/settings-scope-long.png}`. The helper is `scripts/qa/pr65-4227c2a-settings-render.py`.
