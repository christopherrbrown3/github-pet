# PR49 runner trust checks

binary /Users/chris/github-pet-worktrees/qa-verify-bb76ca6/.build/app/GitHubPet.app/Contents/MacOS/GitHubPet sha256 6a842bb448e4c4aaeedf3caedba12fc32589a21367a43fc9314a90f982753d3d

## R1 opt-in refusals
- ok: scenario without --simulate-monitoring-scope: exit 2, nothing written (GitHubPet QA runner: refused: --qa-scenario/--qa-output require --simulate-monitoring-scope; nothing was run or written )
- ok: r1a output dir never created
- ok: scenario with --render-snapshots: exit 2, nothing written (GitHubPet QA runner: refused: --qa-scenario/--qa-output require --simulate-monitoring-scope; nothing was run or written )
- ok: r1b nothing created
- ok: --qa-output without --qa-scenario: exit 2, nothing written (GitHubPet QA runner: refused: --qa-scenario <name|path.json> is required )

## R2 invalid scenarios (exit 2, nothing written)
- ok: invalid bad-label.json: exit 2, nothing written (GitHubPet QA runner: refused: step 1: label must match [a-z0-9][a-z0-9-]{0,39} )
- FAIL: invalid bool-as-number.json: exit 0, listing changed: yes (GitHubPet: mascot pack mona-pet-v1 loaded from /Users/chris/github-pet-worktrees/qa-verify-bb76ca6/.build/app/GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1 )
- FAIL: bool-as-number.json left files in its output dir
- ok: invalid hold-nine.json: exit 2, nothing written (GitHubPet QA runner: refused: hold: "count" must be in 1.0...8.0 )
- ok: invalid hundred-steps.json: exit 2, nothing written (GitHubPet QA runner: refused: scenario needs 1-99 "steps" )
- ok: invalid malformed.json: exit 2, nothing written (GitHubPet QA runner: refused: scenario is not a JSON object )
- ok: invalid number-as-bool.json: exit 2, nothing written (GitHubPet QA runner: refused: clock-advance: "seconds" must be a number in 0.0...86400.0 )
- ok: invalid quit-not-last.json: exit 2, nothing written (GitHubPet QA runner: refused: step 1: quit must be the last step )
- ok: invalid unknown-action.json: exit 2, nothing written (GitHubPet QA runner: refused: step 1: unknown action "explode"; known: account, apply, capture, clock-advance, clock-set, corrupt, corrupt-reload, deliver-all, deliver-newest, deliver-oldest, hold, inject-incident, injec)
- ok: invalid unknown-key.json: exit 2, nothing written (GitHubPet QA runner: refused: step 1 (refresh): unknown key "bogus"; allowed: [] )
- ok: invalid wait-61.json: exit 2, nothing written (GitHubPet QA runner: refused: wait-real: "seconds" must be in 0.0...60.0 )
- ok: unknown built-in name: exit 2, nothing written (GitHubPet QA runner: refused: unknown scenario "no-such-scenario"; built-in: account-a-b-a, corrupt-saved-selected, demo-isolation, incidents-preserved, partial-recovery-new-once, privacy-summary, restore-before-display,)

## R3 output-directory safety
- ok: non-empty dir with a foreign file: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr49/trust/r3-foreign is not empty and was not created by th)
- ok: marker dir with a hard-linked step file: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output entry step-01-x.json is not a single-link regular file (hard link, symlink, directory or other); refusing )
- ok: marker dir with a symlinked runner.json: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output entry runner.json is not a single-link regular file (hard link, symlink, directory or other); refusing )
- ok: output path is a regular file: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr49/trust/r3-file exists and is not a directory )
- ok: output is the home directory: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output /Users/chris is a protected location )
- ok: output under /System: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output /System/github-pet-qa-probe is a protected location )
- ok: output inside the app bundle: exit 2, nothing written (GitHubPet QA runner: refused: --qa-output /Users/chris/github-pet-worktrees/qa-verify-bb76ca6/.build/app/GitHubPet.app/Contents/qa-probe is a protected location )
- ok: victim file unchanged
- ok: foreign file kept
- symlinked ancestor (pre-existing): exit 0; real dir files 10; link still a symlink: yes
- ok: reuse of a runner dir replaced the old runner files (exit 0)
- ok: relative output resolved under the working directory

## R5 determinism
- ok: 6 step records identical apart from defaultsDomain

trust failures: 2
