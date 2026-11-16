# PR50 hostile pack launches, 45befb4e1d4f30acfd826db47ba82c75e94431b6
binary sha256 e858fb56f6b19f0a6e5b38fd22d0a715d81a9ed77318c1371014e48e5c30bfda
mode: GITHUB_PET_PACK_DIR=<pack> GitHubPet --render-snapshots <dir> (fixtures, throwaway suite, self-quit)

## normal
stored id (escaped): qa-normal-pack
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-normal-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr50c/packs/normal
launch line code points: 186, utf8 bytes 186
result: ok

## how-to
stored id (escaped): x\u{202E}evil\u{000A}\u{001B}[31mGitHubPet: mascot pack trusted
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack xevil [31mGitHubPet: mascot pack trusted loaded from /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr50c/packs/how-to
launch line code points: 212, utf8 bytes 212
result: ok

## hostile-dir
stored id (escaped): qa-dir-pack
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-dir-pack loaded from /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr50c/packs/pack [2Jdir
launch line code points: 188, utf8 bytes 188
result: ok

## pending-space-boundary
stored id (escaped): á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack á́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́́… loaded from /private/tmp/claude-501/-Users-chris-github-pet-worktrees-qa-engineer/824f6f45-6a54-4ac4-9b51-996664bf2af7/scratchpad/pr50c/packs/pending-space-boundary
launch line code points: 444, utf8 bytes 700
result: ok

## deep-path
stored id (escaped): qa-deep-pack
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-deep-pack loaded from /private/tmp/claude-501/…/level06-padding-component/level07-padding-component/level08-padding-component/level09-padding-component/qa-deep-pack-dir
launch line code points: 194, utf8 bytes 196
result: ok

## deep-path-1000
stored id (escaped): qa-deep-1000
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-deep-1000 loaded from /private/tmp/claude-501/…/d013-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/d014-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/qa-deep-1000-dir
launch line code points: 182, utf8 bytes 184
result: ok

## hostile-path
stored id (escaped): qa-hostile-path
exit 0; renders 208; empty own domain plist left: True
launch line (escaped): GitHubPet: mascot pack qa-hostile-path loaded from /private/tmp/claude-501/…/level01-padding-component/level02-padding-component/level03-padding-component/x [31mevildir/qa-hostile-path-dir
launch line code points: 188, utf8 bytes 190
result: ok

saved build pids before ['1493', '21468', '31897'] after ['1493', '21468', '31897']
mechanical failures: 0 (grapheme cap and visual output also judged by hand)
