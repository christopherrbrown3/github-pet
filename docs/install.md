# Installing GitHub Pet (development builds)

GitHub Pet is a free project without a paid Apple Developer account. Its builds are **ad-hoc
signed and not notarized**, so macOS asks you to approve the app once before its first launch.
This page shows how to do that with macOS's own settings. You never need to remove quarantine
attributes or turn off Gatekeeper, and you shouldn't.

There is no tagged release or Homebrew cask yet ([#15](https://github.com/christopherrbrown3/github-pet/issues/15)).
Every build of `main` produces a downloadable ZIP as a GitHub Actions artifact.

## Requirements

- macOS 13 Ventura or later.
- Apple Silicon or Intel: the app is a universal binary (arm64 + x86_64). The Intel half is built
  in CI and smoke-tested under Rosetta when the runner has it; it hasn't been tried on Intel hardware.
- For live GitHub data: the [GitHub CLI](https://cli.github.com) (`brew install gh`), signed in
  with `gh auth login`. Without it, GitHub Pet runs on invented Demo data.

## 1. Download

The ZIP is attached to each successful run of the **Swift** workflow on `main` as the artifact
**GitHubPet-app** (kept for 90 days). Downloading artifacts requires a GitHub account.

In a browser: open the repository's **Actions** tab, choose the **Swift** workflow, open the latest
successful run on `main`, and download **GitHubPet-app** under **Artifacts**. GitHub delivers it
as a ZIP that contains:

- `GitHubPet-<version>-<commit>-universal.zip`: the app.
- `GitHubPet-<version>-<commit>-universal.zip.sha256`: its checksum.

With the GitHub CLI:

```sh
run=$(gh run list --repo christopherrbrown3/github-pet --workflow Swift --branch main \
  --status success --limit 1 --json databaseId --jq '.[0].databaseId')
gh run download "$run" --repo christopherrbrown3/github-pet --name GitHubPet-app --dir GitHubPet-download
cd GitHubPet-download
```

## 2. Check the download

In the folder that holds both files:

```sh
shasum -a 256 -c GitHubPet-*-universal.zip.sha256
```

It should print `OK`. If it doesn't, download again; don't open the app.

## 3. Unzip and move to Applications

Double-click the app ZIP (or run `ditto -x -k GitHubPet-*-universal.zip .`), then drag
**GitHubPet.app** into **Applications**.

## 4. First launch: approve the app once

1. Open **GitHubPet** from Applications. macOS says it can't verify the app (because it isn't
   notarized). Choose **Done** (do not move it to the Bin).
2. Open **System Settings → Privacy & Security** and scroll to **Security**. You'll see a message
   that GitHubPet was blocked. Click **Open Anyway**, then confirm with your password or Touch ID.
3. Open GitHubPet again and choose **Open** in the final prompt.

On macOS 15 Sequoia and later this is the only way: Control-clicking the app and choosing **Open**
no longer bypasses the check. On macOS 13–14 you can also Control-click the app, choose **Open**,
and confirm. You approve each downloaded version once. Apple's guidance:
[Open a Mac app from an unknown developer](https://support.apple.com/en-us/102445).

## What to expect

- GitHub Pet is a **menu-bar app**: it has no Dock icon. Look for its icon in the menu bar; the
  mascot appears near the bottom-right of the screen. Quit it from the inbox's power button.
- It starts with **Demo data**: invented items, clearly labelled DEMO. To see your own review
  requests and assigned issues, install and sign in to `gh`, then choose **GitHub CLI (gh)** under
  **Settings → Data source**. GitHub Pet uses `gh`'s sign-in; it never asks for or stores a token.
- Privacy mode is on by default: names and titles stay hidden until you choose **Show details**.

## Updating and removing

To update, download a newer build and replace the app in Applications (approve it once more).
To remove it, quit GitHub Pet and delete **GitHubPet.app**. Its settings live in the
`dev.github-pet.GitHubPet` preferences domain (`defaults delete dev.github-pet.GitHubPet`).

## Building it yourself

With Xcode or just the Command Line Tools:

```sh
gh repo clone christopherrbrown3/github-pet && cd github-pet
scripts/package-zip.sh            # universal app + ZIP + .sha256 in .build/dist, self-verified
open .build/app/GitHubPet.app
```

A build you make yourself isn't quarantined, so it opens without the approval step.
`scripts/build-app.sh` builds just the app (`--universal` for arm64 + x86_64). See
[development.md](development.md) for tests and QA hooks.
