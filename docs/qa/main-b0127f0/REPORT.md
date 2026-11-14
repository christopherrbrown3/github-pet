# Final main artifact QA — PASS

Exact main `b0127f00e4dec92b5b9111a46b76c7191334706f`, [push CI43609749683](https://github.com/christopherrbrown3/github-pet/actions/runs/43609749683) SUCCESS. Independent final artifact sanity only; accepted integration/behavior evidence reused.

- Stable ZIP: `/Users/chris/github-pet-builds/b0127f0/GitHubPet-0.1.0-b0127f0-universal.zip`; app: `/Users/chris/github-pet-builds/b0127f0/GitHubPet.app`.
- Computed SHA-256 and shipped checksum agree: `f427650c9624b64dc6a89871ffd952342dea429df10441c34ccf5968cf6952a5`. This digest also appears in the freshly retrieved actual main CI package log.
- ZIP integrity PASS; every app-file byte in the ZIP matches the stable extracted app. `codesign --verify --deep --strict --verbose=2` PASS; ad-hoc, no TeamIdentifier. `lipo`: x86_64 + arm64.
- Signed plist: version0.1.0, **build71**, exact full main source SHA above, expected bundle ID/LSUIElement/minimum macOS13.0. Full Git history independently counts71; source tree `c69eba8f2eab2696a11f9597e499e842ffaa70dc` exactly matches accepted561fafc. All 12 mascot frames and manifest match accepted source bytes.
- Independently confirmed live GitHub run metadata: push event, exact main SHA, overall SUCCESS and **Intel slice smoke (Rosetta) SUCCESS**. Freshly fetched actual CI log says **“intel-smoke: x86_64 slice ran the snapshot scenario under Rosetta”**, timestamp2026-11-14T15:34:12Z. This is actual CI Rosetta execution, not a physical Intel Mac claim. CI reports277 tests/eight packaging regressions/GUI render PASS; no local suite was repeated.

**No reproducible final artifact defect found.** No local build, app launch, quarantine manipulation, settings/permission changes, release/tag or backlog work. Clean-Mac quarantined first launch, installation/settings preservation, physical Intel hardware and broader desktop/accessibility acceptance remain open under#15/#4 as applicable. Logs and read-only sanity script saved in docs/qa/main-b0127f0 and scripts/qa/main-b0127f0-sanity.py. QA idle after reporting to PM.
