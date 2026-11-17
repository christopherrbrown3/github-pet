# Installing GitHub Pet

GitHub Pet is a free project without a paid Apple Developer account. Its builds are **ad-hoc
signed and not notarized**, so macOS asks you to approve the app once before its first launch.
This page shows how to do that with macOS's own settings. You never need to remove quarantine
attributes or turn off Gatekeeper, and you shouldn't.

Builds are published on the [Releases page](https://github.com/christopherrbrown3/github-pet/releases);
the current one is the pre-release
[v0.1.0-beta.1](https://github.com/christopherrbrown3/github-pet/releases/tag/v0.1.0-beta.1). A Homebrew
cask is planned but not available yet ([#15](https://github.com/christopherrbrown3/github-pet/issues/15)).

## Requirements

- macOS 13 Ventura or later.
- Apple Silicon or Intel: the app is a universal binary (arm64 + x86_64). The Intel half is built
  in CI and smoke-tested under Rosetta when the runner has it; it hasn't been tried on Intel hardware.
- For live GitHub data: the [GitHub CLI](https://cli.github.com) (`brew install gh`), signed in
  with `gh auth login`. Without it, GitHub Pet runs on invented Demo data.

## 1. Download

Open the [Releases page](https://github.com/christopherrbrown3/github-pet/releases) and, under the newest
release, download both assets into the same folder (no GitHub account needed):

- `GitHubPet-<version>-<commit>-universal.zip`: the app.
- `GitHubPet-<version>-<commit>-universal.zip.sha256`: its checksum.

Beta builds are marked **Pre-release**. GitHub's "latest release" link skips pre-releases, so use the
Releases page itself (or the command below) rather than `/releases/latest`.

With the GitHub CLI:

```sh
tag=$(gh release list --repo christopherrbrown3/github-pet --exclude-drafts --limit 1 --json tagName --jq '.[0].tagName')
test -n "$tag" && test "$tag" != null || { echo "No release is available yet" >&2; exit 1; }
gh release download "$tag" --repo christopherrbrown3/github-pet \
  --pattern 'GitHubPet-*-universal.zip' --pattern 'GitHubPet-*-universal.zip.sha256' --dir GitHubPet-download
cd GitHubPet-download
```

Developers who want an unreleased build of `main` can still take the **GitHubPet-app** artifact of a
successful `main` push run of the **Swift** workflow in GitHub Actions (needs a GitHub account); see the
[development guide](development.md).

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

## Keyboard and VoiceOver access

The **menu-bar icon** and **Settings** are the intended keyboard route. They use standard macOS
controls, but keyboard behaviour has **not been verified on a real Mac** yet, so treat the
following as what to expect, not a guarantee:

- **Reaching the menu-bar icon is a separate step.** GitHub Pet has no Dock icon or app menu of
  its own, so you reach its icon the way you reach any menu-bar item, for example with the
  system's "Move focus to status menus" shortcut (System Settings → Keyboard → Keyboard
  Shortcuts → Keyboard), if it is enabled on your Mac.
- **Tab only reaches buttons when Keyboard Navigation is on** (System Settings → Keyboard →
  Keyboard navigation). With it off, Tab moves only between text fields and lists.
- **Activation keys depend on the control.** Space usually presses the focused button; Return
  triggers the default button of a window or sheet, which is not always the focused one.

The floating mascot is a mouse and VoiceOver target only: it is not focusable from the keyboard,
but everything it opens (the inbox) is reachable from the menu-bar icon. With VoiceOver the
mascot reads as one button and pressing it opens the inbox. This has been checked from static
accessibility output only; a live VoiceOver pass has not been done yet.

## Updating

To update, download a newer build and replace the app in Applications (approve it once more).

Your settings live in the `dev.github-pet.GitHubPet` preferences domain, which doesn't depend on
where the app is. Replacing the app with a newer ZIP build should therefore keep them, but this
has **not been tested** on a clean install yet, so check Settings after updating.

## Uninstalling

1. Quit GitHub Pet from the inbox's power button.
2. Delete **GitHubPet.app** from Applications (move it to the Bin).
3. Optional: remove its saved settings. This command is for you to run in Terminal; nothing in the
   app or the ZIP runs it for you:

   ```sh
   defaults delete dev.github-pet.GitHubPet
   ```

4. If you turned on **Open at login**, turn it off first: in GitHub Pet's **Settings → Startup**,
   or under **System Settings → General → Login Items**. Do this before step 2, while the app is
   still installed. If you already deleted the app, check Login Items and remove GitHub Pet there
   if it is still listed. Open at login has **not been verified on a real Mac** with this
   ad-hoc-signed build yet; Settings shows whatever macOS reports (On, Off, Pending approval or
   Unavailable).

Uninstalling does not touch the GitHub CLI or its sign-in. A Homebrew cask is planned but not
available, so there is no `brew uninstall` path yet.

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
