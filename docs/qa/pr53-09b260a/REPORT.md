# PR53 (#52) functional QA: GitHub CLI setup links

Head **`09b260a38efdec0c9606f3977675dc6d85c847c4`**, saved Developer-built app `/Users/chris/github-pet-builds/pr53-09b260a/GitHubPet.app` (Info.plist revision equals the head, binary sha256 `b6ed37b5…9ab66`). Verdict: **functional PASS** within the limits below. QA: Claude QA t4x (claude-opus-5-5), driven by `scripts/qa/pr53-gh-setup.py`. Mechanical log: `functional.md`.

## Results

- **No gh during setup renders:** `--render-snapshots` ran with a logging fake `gh` both first on PATH and as `GITHUB_PET_GH_PATH`. Zero invocations. Exit 0.
- **Real engine state** (report lines): `ghmissing` and `unauthenticated` both show source=githubCLI, demo=false, badge `?`, rows 0, unseen 0, no clip. State texts are "GitHub CLI not found" and "Not signed in to GitHub CLI". Links are `Get GitHub CLI` and `How to sign in` respectively.
- **8 PNGs viewed** (Inbox and Settings, light and dark, both states):
  - Missing gh: "GitHub CLI not found", "Install it with: brew install gh" and a **Get GitHub CLI** link.
  - Signed out: "Not signed in to GitHub CLI", "Run: gh auth login", and **How to sign in** plus **Copy command**.
  - Settings shows Source = GitHub CLI (gh) with the same links under the error.
  - No account, login, repository or token data appears anywhere.
  - The Inbox shows an explicit error with an unknown `?` count, never a verified-empty inbox.
  - Dark mode is legible.
- **Only cli.github.com links:** the built binary gains exactly two URL strings compared with the saved main build b0127f0: `https://cli.github.com/` and `https://cli.github.com/manual/gh_auth_login`. Both are https on cli.github.com. No other new URL.
- **Live launches, real CLI client** (`--gh`, throwaway `--defaults-suite`, `--reset-settings`, normal quit by PID, suite deleted afterwards):
  - Missing override path (`…/gh` that does not exist): gh never executed. The PATH trap was never used, so the override is the only candidate and there is no fallback to an installed gh. Stayed up and quit with exit 0.
  - Non-executable override (mode 644): never executed, no PATH fallback, exit 0.
  - Signed-out fake gh: the only command run was `auth status --active --hostname github.com`. No API or graphql call was made after the sign-out answer. No PATH fallback. Exit 0.
  - Stderr held only the normal mascot launch line. No sockets were open at 10 s.
- **Preferences hygiene:** no `dev.github-pet.render-snapshots.<pid>.plist` remained 20 s after the render exit. Main leaves one per run (also seen during PR50 QA). The real `dev.github-pet.GitHubPet` preferences hash was unchanged. The saved b0127f0 app (pid 31897) was untouched.

## Limits

- The Inbox/Settings state for the **live** missing, non-executable and signed-out launches was not observed visually: no GUI, Screen Recording or Accessibility in this session. Their mapping is shown by the gh invocation records plus the offscreen renders of the same states through the real engine.
- No browser click-through of the links, no pasteboard check of Copy command, no VoiceOver (accessibility hints are not verified), no physical Intel and no real authentication.
- The renders are offscreen and drawn by the app itself.
- Observation, not a PR53 defect: light-mode offscreen Settings toggles render in an inactive grey that makes on/off hard to read. Dark mode is clear. This is a renderer artifact and is not claimed as a desktop appearance.
