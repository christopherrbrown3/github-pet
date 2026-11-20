# Updates (#90)

GitHub Pet updates itself with [Sparkle 2](https://sparkle-project.org) (pinned to exactly 2.10.1). Builds are
ad-hoc signed and not notarized (#89 is post-beta), so **the trust root during the beta is Sparkle's EdDSA
signature on each update ZIP**, not Apple notarization. Sparkle clears quarantine on updates it has verified
and installed. This is an accepted exception, limited to Sparkle-verified updates; the app never asks anyone to
turn off Gatekeeper. The very first install still needs **Open Anyway** (docs/install.md).

A **lost or leaked production key has no in-band recovery** on ad-hoc builds: users would have to reinstall by hand.

## What users get

- **Check for Updates…** in the menu-bar menu and in Settings › GitHub › Software updates (installed version and build,
  last check, automatic-check and automatic-install toggles, beta opt-in). A scheduled check never opens a window
  over your work: the menu shows a quiet "Version X available" line and Sparkle waits until you check.
- Sparkle's consent prompt asks about automatic checks. Checks run at most every 24 hours. Installing needs your OK
  unless you turn on "Install updates automatically" in Settings. Sparkle's first-run prompt has the same checkbox, but
  the app treats silent install as on only when it was turned on in Settings: anything else is switched back off, so a
  default keystroke in the prompt can never enable it. A staged silent update shows "installs when GitHub Pet quits".
- **Channels:** Stable is the default. Beta items (`<sparkle:channel>beta</sparkle:channel>`) are offered only to an
  installed prerelease build or to a user who turned on "Include beta releases". Nobody is moved to beta by a check.
- System profiling is off; no sign-in, `gh` or token is used.
- A build without a valid signing key (every local and CI build until the release key is committed) shows
  **Updates not configured** and never starts the updater.

## Build-time configuration

`scripts/build-app.sh` writes these Info.plist keys. There is **no runtime environment variable or launch argument**
that changes any of them.

| Key | Value |
|---|---|
| `SUFeedURL` | `https://raw.githubusercontent.com/christopherrbrown3/github-pet/main/updates/appcast.xml` |
| `SUPublicEDKey` | contents of `updates/sparkle-public-ed-key.txt`; omitted while the file has no key |
| `SUAutomaticallyUpdate` | `false` (install needs the user's OK) |
| `SUAllowsAutomaticUpdates` | `true` (the user may opt in to silent install) |
| `SUScheduledCheckInterval` | `86400` |
| `SUVerifyUpdateBeforeExtraction` | `true` (the EdDSA signature is checked before the ZIP is unpacked; our ZIPs are plain `ditto` archives, which this supports) |
| `SUEnableSystemProfiling`, `SUEnableAutomaticChecks` | absent (Sparkle asks the user) |
| `GitHubPetReleaseVersion`, `CFBundleShortVersionString` | with `RELEASE_VERSION=0.1.0-beta.4` both become the full release version (Sparkle's dialogs say "you have X" from the latter, and a prerelease build follows beta); without it the short version is `VERSION` |

`Sparkle.framework` is copied into `Contents/Frameworks` with its symlinks, its XPC services are removed (they are
for sandboxed apps), the binary gets the rpath `@executable_path/../Frameworks`, and the framework's `Autoupdate` and
`Updater.app`, then the framework, then the app are ad-hoc signed inside-out (no `--deep` signing).
`scripts/test-update-build.sh` checks all of this, and `package-zip.sh` re-checks it on the unpacked ZIP.

### QA builds

QA builds must never touch the real app's preferences or feed. Overrides are build-time only:

    BUNDLE_ID_SUFFIX=.qa \
    SPARKLE_FEED_URL=http://127.0.0.1:8123/appcast.xml \
    SPARKLE_PUBLIC_KEY_FILE=/path/to/qa-public-key.txt \
    RELEASE_VERSION=0.1.0-beta.9 \
      scripts/build-app.sh release

- `BUNDLE_ID_SUFFIX=.qa` gives the bundle ID `dev.github-pet.GitHubPet.qa`: its own preferences domain and its own
  Open-at-login identity.
- `SPARKLE_FEED_URL` must be https, or http on `127.0.0.1`/`localhost`; the latter adds App Transport Security's
  local-network exception to that build only.
- `SPARKLE_PUBLIC_KEY_FILE` is a file with one Sparkle public key (plus optional `#` comment lines).
  `Tests/fixtures/sparkle-test-public-key.txt` is a **test-only** public key whose private half was discarded;
  it only exercises the build script. For a real update run, QA generates a throwaway pair under a separate
  Keychain account (`generate_keys --account github-pet-qa`, public key printed) and signs the test ZIP with
  `sign_update --account github-pet-qa`. Never use the production account, and delete the QA item afterwards.
- A default build always has the committed feed and the committed key (or none), never a test key; the regression
  script enforces it.

## One-time key setup (Chris, on the Mac that will sign releases)

Agents never generate, read, export or commit the production private key.

1. `swift package resolve`, then `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. It stores the private key in
   your login Keychain and prints the public key.
2. Back the private key up now: `generate_keys -x ~/Desktop/github-pet-sparkle-private.key`, put that file in your
   password manager, and delete it from the Desktop. Without a backup, a lost Keychain means a manual reinstall for
   every user.
3. Put the printed public key on its own line in `updates/sparkle-public-ed-key.txt` (below the comments) and commit
   it. Builds made after that include `SUPublicEDKey`, and the updater turns on.

## Cutting a release

The ZIP that users receive is **the exact artifact CI built and tested**, never a local rebuild.

1. **Tag.** On `main`, with `VERSION` set to the core version, push a tag `v0.1.0-beta.4` (or `v0.1.0` for stable).
   The workflow refuses a tag that isn't on `main` or isn't a release version. (To try a candidate from a branch,
   run the workflow manually with the `release_version` input; that artifact is for testing, not publishing.)
2. **CI artifact.** The workflow runs the full suite and packages the universal app with `RELEASE_VERSION` taken
   from the tag, using the committed key and feed. It checks the app's `GitHubPetReleaseVersion`,
   `CFBundleShortVersionString`, `SUPublicEDKey` and `SUFeedURL`, runs the render check and the Intel smoke on
   that very app, and uploads `GitHubPet-release-<version>` (ZIP + `.sha256`). The job summary lists the commit,
   build number and SHA-256.
3. **QA verifies** that artifact (its SHA-256 matches the summary) before anything is published.
4. **GitHub pre-release.** Create the release for the tag (mark betas as pre-release) and upload that ZIP and its
   `.sha256` unchanged.
5. **Sign and publish the feed.** Chris downloads the same ZIP from the release and runs
   `scripts/release-appcast.sh v0.1.0-beta.4 <that zip>`. It refuses a ZIP whose app disagrees with the tag or the
   committed key, signs the ZIP with `sign_update` from the login Keychain (the script never reads the private key),
   and adds or replaces the item in `updates/appcast.xml`: enclosure = the GitHub Release asset URL,
   `sparkle:version` = `CFBundleVersion`, `sparkle:shortVersionString` = the release version, `sparkle:channel` =
   `beta` for prereleases, release-notes link = the GitHub release page. `sparkle:version` must keep increasing:
   the script refuses a build number that isn't newer.
6. **Appcast PR.** Open a PR with only the `updates/appcast.xml` change. Users see the update once it is on `main`.

`updates/appcast.xml` is committed empty but valid. `scripts/test-release-appcast.sh` tests the script with a fake
signer.

## Known limits

- Ad-hoc signatures change with every build, so macOS may treat an updated app as a new item for Open at login and
  similar approvals. QA checks the login status after an update.
- First install still needs Open Anyway; automatic update does not replace that.
- Anyone holding the production key can ship an update that installs without a Gatekeeper prompt.
- Builds before this feature (beta 1-3) have no updater: update them by hand once.
