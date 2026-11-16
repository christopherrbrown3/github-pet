# PR55 3f20b72 QA: main-merge review and loop-flag re-check

**PASS** at `3f20b7274517954d9ae41e8680087dd444e3b3b7`.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task J from PM t61, 2026-11-16.

- **CI:** 43892126983 completed SUCCESS on this exact head, confirmed with `gh run view`.
- **Main merge `e16b740`** (parents 371c79f and main b74078b, which includes the PR50 MascotPack changes): `git merge-tree --write-tree` gives `09d2561…`, identical to e16b740's tree. So it was a clean automatic merge with no manual resolution.
- **PR diff against its merge base:** only `MascotPack.swift` (+6) and `MascotPackTests.swift` (+22). It is the same `spec.loop == (state == .idle)` rule as 371c79f, now placed beside PR50's sanitizing code without interacting with it. MascotPack validation behaves the same as before.
- **`3f20b72`:** the error text now uses `q(s)`, the same label sanitizer as every other state error. The new test feeds the hostile name `"id\u{202E}le\nx"` and expects `'idle x'`. For real `MascotState` names `q()` returns them unchanged, so the text users see does not change.
- **Single confirming launch, as PM allowed:**
  - **Artifact:** the CI artifact from that run. ZIP SHA256 `a7aa6bb36e30c26479ec0a4c88056e2e12ac889b0d4ba7ed4b49db6c90b42c84` matches the sidecar. The Info.plist revision equals 3f20b72 (build 144), and strict codesign passes.
  - **Launch:** offscreen `--render-snapshots <dir> --fixtures` with `GITHUB_PET_PACK_DIR` pointing at a private copy of the bundled pack, with idle `loop: false` and attention `loop: true`. PID 33481, exit 0.
  - **stderr:** the rejection line is **byte-identical** to the 371c79f run. It names both states with their expected values, and urgent (which is valid) is not flagged.
  - **PNGs (viewed):** `settings.png` shows the same orange two-state rejection, and `01-baseline-mascot.png` shows the purple placeholder with DEMO and badge 3.
  - **Safety:** gh tripwire 0, no preference domains or files changed, protected PID 31897 unchanged, no QA app left running.
- **Not repeated:** the valid-pack launch. Acceptance is unchanged by the merge and the 371c79f valid-pack result still applies.

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, `completion.json`, and `wrong-loop-flags/{fixture.json, pack/manifest.json, launch.json, stderr.bin, completion.json, before.json, after.json, snapshots/settings.png, snapshots/01-baseline-mascot.png}`. The helper is `scripts/qa/pr55-3f20b72-loop-flags.py`.
