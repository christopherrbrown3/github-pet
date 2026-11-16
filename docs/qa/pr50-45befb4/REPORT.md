# PR50 (#40) final functional QA: delta at 45befb4

Head **`45befb4e1d4f30acfd826db47ba82c75e94431b6`** (CI 43799845701 SUCCESS). Release app built in a fresh detached worktree `qa-verify-45befb4` (Info.plist revision verified). Verdict: **functional PASS.** The directory-path usability defect from d0448c1 is fixed. QA: Claude QA t4x (claude-opus-5-5).

Delta since d0448c1: the launch line's pack path uses `PackLabel.sanitizePath`: a 160-grapheme cap with middle truncation that keeps the first 24 graphemes and a tail starting at a folder boundary. Names and ids keep the 48-grapheme cap.

The actual built app was launched with `GITHUB_PET_PACK_DIR` in `--render-snapshots` mode (`scripts/qa/pr50-hostile-packs.py`, `QA_CASES` subset). Raw stderr is in `stderr-*.bin`, and the summary is in `hostile-packs.md` and `hostile-packs.json`.

| Case | Shown path (escaped) | Result |
|---|---|---|
| normal (136-char path) | full path, unchanged | ok |
| deep-path (about 400 chars, 12 levels) | `/private/tmp/claude-501/…/level06-…/level09-padding-component/qa-deep-pack-dir` (146 code points) | head kept, tail starts at `/`, pack folder name kept |
| deep-path-1000 (about 850 chars, 17 levels; 1000 exceeds macOS PATH_MAX once frame files are added) | `/private/tmp/claude-501/…/d013-x…/d014-x…/qa-deep-1000-dir` (134) | ok |
| hostile-path (component `x\n\e[31mevil‮​dir` mid-path, deep) | `…/level03-padding-component/x [31mevildir/qa-hostile-path-dir` | single line; newline→space; ESC, RTL and ZWSP dropped; tail kept |
| hostile-dir (final component `pack\n\e[2J‮dir`) | `…/packs/pack [2Jdir` | sanitized and now visible (cut off at d0448c1) |
| pending-space-boundary (`a`+254×U+0301+` bc`) | id shows `a`+254×U+0301+`…` | no regression |
| how-to (hostile name) | `xevil [31mGitHubPet: mascot pack trusted`, single line | no regression |

All 7 cases: exactly one launch line, exit 0, the custom pack loaded and rendered (208 PNGs), and no control, bidi or format characters in stderr. Real preferences were unchanged and the saved b0127f0 app was untouched. Earlier evidence (33f36f1 18-case sweep, d0448c1 boundary) is retained by unchanged label code and was not re-run in full.

Accepted cosmetic limit (unchanged): ZWJ emoji sequences split. Limits: Settings error text was not observed (no GUI, Screen Recording or Accessibility). No pointer, VoiceOver or Intel checks.
