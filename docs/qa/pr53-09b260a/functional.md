# PR53 functional QA, saved app /Users/chris/github-pet-builds/pr53-09b260a/GitHubPet.app, revision 09b260a38efdec0c9606f3977675dc6d85c847c4
binary sha256 b6ed37b51f5fae14a247d7151691ff4a3ff8c95a90b27ec195a3b3bc86b9ab66

## A. --render-snapshots, logging fake gh on PATH and as GITHUB_PET_GH_PATH
- ok: render exit 0
- ok: gh invocations during render: []
- ok: no dev.github-pet.render-snapshots.14800.plist 20 s after exit (other agents' new files ignored: ['dev.github-pet.render-check.16024.plist', 'dev.github-pet.render-snapshots.16036.plist'])
  setup=ghmissing source=githubCLI demo=false badge=? rows=0 unseen=0 clip=none state=GitHub CLI not found links=["Get GitHub CLI"]
  setup=unauthenticated source=githubCLI demo=false badge=? rows=0 unseen=0 clip=none state=Not signed in to GitHub CLI links=["How to sign in"]
- ok: two setup report lines
- ok: ghmissing: real CLI source, no rows/unseen/clip, link 'Get GitHub CLI'
- ok: unauthenticated: real CLI source, no rows/unseen/clip, link 'How to sign in'
- ok: 8 gh-setup PNGs

## B. live --gh launch, missing gh
- ok: stayed up 10 s, quit normally (exit 0)
- ok: no gh from PATH used despite the override
- ok: fake gh never executed: []
  stderr: GitHubPet: mascot pack mona-pet-v1 loaded from /Users/chris/github-pet-builds/pr53-09b260a/GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1
  sockets at 10 s (public status client expected; no gh): 0

## B. live --gh launch, non-executable gh
- ok: stayed up 10 s, quit normally (exit 0)
- ok: no gh from PATH used despite the override
- ok: fake gh never executed: []
  stderr: GitHubPet: mascot pack mona-pet-v1 loaded from /Users/chris/github-pet-builds/pr53-09b260a/GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1
  sockets at 10 s (public status client expected; no gh): 0

## B. live --gh launch, signed-out gh
- ok: stayed up 10 s, quit normally (exit 0)
- ok: no gh from PATH used despite the override
- ok: only auth status run: ['auth status --active --hostname github.com']
  stderr: GitHubPet: mascot pack mona-pet-v1 loaded from /Users/chris/github-pet-builds/pr53-09b260a/GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1
  sockets at 10 s (public status client expected; no gh): 0
- ok: real preferences unchanged
- ok: saved b0127f0 process untouched ['14766', '31897']

mechanical failures: 0; PNG content judged by hand
