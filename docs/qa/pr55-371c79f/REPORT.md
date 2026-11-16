# PR55 371c79f QA: mascot pack loop flags (#14)

**Source review PASS and scoped functional PASS** at `371c79fe7ddbe9526a0bd5f0302a7ecf05d44ed6`. There are no findings above INFO.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task G from PM t61, 2026-11-16. The worktree `developer-pack-loop` was not touched.

## Source/diff review (`gh pr diff 55`)

The diff touches two files: `MascotPack.swift` (+6) and `MascotPackTests.swift` (+19).

- **Rule:** in `MascotPack.validate` (`MascotPack.swift:257`), every required `MascotState` must satisfy `spec.loop == (state == .idle)`. If it doesn't, the error is `.wrongLoopFlag(state, expected:)`.
- **Errors are collected:** the error is added alongside the other per-state checks, so every wrong flag is reported. It is checked after the frame-count guard, so it fires only for states that pass that guard.
- **Matches the renderer:** the renderer never reads `loop`. `git grep` finds only this validation, so the rule matches actual playback (idle loops, event clips play once).
- **Bundled pack is valid:** the bundled `mona-pet-v1` declares idle true, attention false and urgent false, so it passes.
- **Message:** `state '<s>' must declare "loop": <bool> (idle loops; attention and urgent play once)`.
- **Tests:** they cover idle false, attention true and urgent true as rejections, idle true and urgent false as accepted, and the description text.

INFO notes:

- **Unsanitized state name:** the new description interpolates `s` directly, while PR50 (now on main) passes state names through `q()`/`PackLabel.sanitize`. `s` is always a fixed internal `MascotState.rawValue`, so nothing author-controlled is shown. Adding `q(s)` after merging main would be a consistency nicety.
- **Branch is behind main:** its merge base is 9d8299a. `git merge-tree` against current main (which includes PR50 and PR59) and against PR50 head 49f3a17 are both textually clean. The Developer will merge main; QA should review that merge when it happens.
- **Non-boolean `loop`:** a value such as 0/1 or a missing key is rejected earlier by Codable decoding (`unreadableManifest`), which is existing behaviour.

## Functional (actual CI artifact for the exact head)

An exact-head green CI already existed, so no new build was needed.

| Item | Value |
|---|---|
| CI | 43800994229 (pull_request), completed SUCCESS on headSha 371c79f… |
| Artifact | `GitHubPet-app` 14196476874, downloaded with gh |
| ZIP SHA256 | see `provenance.json` (matches the sidecar) |
| Info.plist | `GitHubPetSourceRevision` = 371c79fe7ddbe9526a0bd5f0302a7ecf05d44ed6 (**verified equal**). Strict codesign PASS. |

**Method:**

- **Helper:** `scripts/qa/pr55-371c79f-loop-flags.py`, which uses the same approach as the PR50 asset-error runner.
- **Launches:** two offscreen renderer launches of the artifact, each run as `--render-snapshots <fresh dir> --fixtures` with `GITHUB_PET_PACK_DIR` pointing at a private copy of the artifact's bundled pack. No normal launch, CUA, signals or quit.
- **gh tripwire:** not invoked.
- **Preferences:** the hash-only snapshots show **no changed domains or files** for either launch.
- **Protected app:** PID 31897 kept its original start time. No QA app was left running.

| Case | Launch | Observed | Verdict |
|---|---|---|---|
| Wrong loop flags (idle `false`, attention `true`; everything else unchanged) | PID 8347, exit 0 | stderr: `mascot placeholder (pack rejected: state 'idle' must declare "loop": true (…); state 'attention' must declare "loop": false (…))`. Both errors are present and urgent, which is valid, is not flagged. `settings.png` (viewed) shows the same two-part rejection in readable orange text. `01-baseline-mascot.png` (viewed) shows the purple native placeholder with the DEMO label and badge 3. | PASS: safe rejection, clear error, placeholder |
| Valid pack (unmodified copy) | PID 11028, exit 0 | stderr: `mascot pack mona-pet-v1 loaded from …/valid-pack/pack`. `01-baseline-mascot.png` (viewed) shows the custom pack art with the DEMO label and badge 3. `settings.png` (viewed) has no rejection text. | PASS: accepted |

The valid run's Settings shows "GitHub CLI not found". That comes from the gh tripwire replacing gh on PATH in this harness; it is not a product finding.

## Limits

- **Coverage:** only one wrong-flag combination was tested through the app. The urgent combination and the single-flag cases are covered by the Developer's unit test.
- **Build age:** the artifact is built from the branch, which is behind main. After main is merged, rerun only this pair if `MascotPack` validation or the error descriptions change.
- **Animation not checked:** no animation playback timing was verified.
- **Not covered:** native window, VoiceOver and Intel.

## Evidence committed

- **Top level:** `ci.json`, `artifact-metadata.json`, `provenance.json`, `completion.json`.
- **Per case** (`wrong-loop-flags` and `valid-pack`): `fixture.json`, `pack/manifest.json`, `launch.json`, `stderr.bin`, `completion.json`, `before.json`, `after.json`, `snapshots/settings.png`, `snapshots/01-baseline-mascot.png`.
- **Kept local only:** the ZIP, the extracted app, the pack frames and the other PNGs.
