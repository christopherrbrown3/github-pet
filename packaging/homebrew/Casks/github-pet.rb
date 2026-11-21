cask "github-pet" do
  version "0.1.0-beta.4"
  sha256 "cde6a309fa064b175afda2e5c62c765150821e6474653f1069a9aa2938c83ea6"

  # The asset name carries the build's base version and commit, not the release tag, so
  # scripts/update-cask.sh rewrites it together with version and sha256.
  url "https://github.com/christopherrbrown3/github-pet/releases/download/v#{version}/GitHubPet-0.1.0-89876e7-universal.zip"
  name "GitHub Pet"
  desc "Menu-bar pet that surfaces your GitHub review requests and assigned issues"
  homepage "https://github.com/christopherrbrown3/github-pet"

  # Sparkle updates the app in place; `brew upgrade` skips it unless run with --greedy.
  auto_updates true
  depends_on macos: :ventura

  app "GitHubPet.app"

  uninstall quit: "dev.github-pet.GitHubPet"

  zap trash: [
    "~/Library/Caches/dev.github-pet.GitHubPet",
    "~/Library/HTTPStorages/dev.github-pet.GitHubPet",
    "~/Library/Preferences/dev.github-pet.GitHubPet.plist",
    "~/Library/Saved Application State/dev.github-pet.GitHubPet.savedState",
  ]

  caveats <<~EOS
    GitHub Pet is ad-hoc signed and not notarized, so macOS blocks the first launch.
    Open it once, then choose Done, open System Settings > Privacy & Security, click
    "Open Anyway" next to GitHubPet and confirm. Do not remove quarantine or turn off
    Gatekeeper. You approve each version you install through Homebrew; in-app Sparkle
    updates need no further approval.

    Live data needs the GitHub CLI, signed in:
      brew install gh
      gh auth login
    Without it the app shows setup guidance and an "unavailable" state, never an empty inbox.
  EOS
end
