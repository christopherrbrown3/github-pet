# Updates (#90)

GitHub Pet updates itself with [Sparkle 2](https://sparkle-project.org) (pinned to exactly 2.10.1). Builds are
ad-hoc signed and not notarized (#89 is post-beta), so **the trust root during the beta is Sparkle's EdDSA
signature on each update ZIP**, not Apple notarization. Sparkle clears quarantine on updates it has verified
and installed. This is an accepted exception, limited to Sparkle-verified updates; the app never asks anyone to
turn off Gatekeeper. The very first install still needs **Open Anyway** (docs/install.md).

A **lost or leaked production key has no in-band recovery** on ad-hoc builds: users would have to reinstall by hand.

## What users get

- **Check for Updates…** in the menu-bar menu and in Settings › GitHub › Software updates (installed version and build,
  last check, automatic-check and automatic-install toggles, beta opt-in).
- **Automatic checks are on by default (#149).** A new install checks without Sparkle's consent prompt; anyone who
  already chose in that prompt or in Settings keeps their choice (see "Existing installs" below), and Settings can
  turn checks off. A check is a read-only download of the static appcast in this repository: no sign-in, token or
  system profile is sent.
- **How often:** Sparkle's schedule runs every 6 hours. The app also asks Sparkle for a background check about a
  minute after launch and 30 seconds after the Mac wakes, but only when automatic checks are on, Sparkle is idle and
  the last check is at least 6 hours old. Several wakes in a row make one check.
- **No windows from background checks**, not even right after launch: Sparkle waits (gentle reminders). What a check
  finds shows as a small **dot on the menu-bar icon** (VoiceOver: "…, update available: version X"), an
  **"Update available: Version X" banner** in the Inbox header with **Update…** and **Later**, and the quiet
  "Version X available" lines in the menu and Settings. The banner's Update… opens Sparkle's normal window, which
  shows release notes and still asks before installing. **Later** hides the dot and banner for that version until a
  newer one is found or 24 hours pass (stored as `update.indicatorLaterVersion`/`update.indicatorLaterDate`); the menu
  and Settings lines stay. The indicator is announced to VoiceOver once when it appears. It is never part of the
  desktop pet's count badge, the inbox count or the alert icon, which are for GitHub work.
- Installing needs your OK unless you turn on "Install updates automatically" in Settings. Sparkle's first-run prompt
  had the same checkbox (it no longer appears for new installs), but the app treats silent install as on only when it
  was turned on in Settings: anything else is switched back off, so a default keystroke in the prompt can never
  enable it. A staged silent update shows "installs when GitHub Pet quits" and no dot or banner.
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
| `SUEnableAutomaticChecks` | `true` (#149: checks on for new installs, no consent prompt; a choice stored in the user's defaults wins) |
| `SUScheduledCheckInterval` | `21600` (6 hours; was `86400`) |
| `SUVerifyUpdateBeforeExtraction` | `true` (the EdDSA signature is checked before the ZIP is unpacked; our ZIPs are plain `ditto` archives, which this supports) |
| `SUEnableSystemProfiling` | absent (off; Sparkle never sends a system profile) |
| `GitHubPetReleaseVersion`, `CFBundleShortVersionString` | with `RELEASE_VERSION=0.1.0-beta.4` both become the full release version (Sparkle's dialogs say "you have X" from the latter, and a prerelease build follows beta); without it the short version is `VERSION` |

### Existing installs (#149)

Sparkle reads `SUEnableAutomaticChecks` and `SUScheduledCheckInterval` from the app's user defaults first and the
Info.plist second. After updating from Beta 6 or earlier:

- Someone who answered Sparkle's consent prompt, or used the Settings toggle, has `SUEnableAutomaticChecks` stored in
  `dev.github-pet.GitHubPet` defaults. That value still wins: **Yes stays on and No stays off.**
- Someone who never saw the prompt (Sparkle asks on the second launch) has nothing stored, so the new Info.plist value
  applies: checks turn on, and the prompt no longer appears.
- Nothing in the app ever writes `SUScheduledCheckInterval`, so every install moves from 24 to 6 hours.
- `SUAutomaticallyUpdate` (silent install) is unchanged: on only with `update.silentInstallOptIn` from Settings.
  The last check time and any version skipped in Sparkle's window carry over.

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

The ZIP that users receive is **the exact artifact one CI run built and tested**, never a local rebuild and never
a second build from the tag. A tag push does not build or upload anything.

0. **README.** Before the CI build, merge a PR that brings `README.md` up to date for this release: the
   **Download Beta N** link points at the new tag's release page, the in-app updates line lists the new beta, and any
   text, screenshots or alt text for features in this release are current, and version statements
   such as "describes the Beta N app" in docs/features.md name the new beta. The tag's README is the one the release
   notes link to, so it must be right before the build.
1. **CI artifact.** Run the Swift workflow manually (Actions › Swift › Run workflow) **on `main`** with
   `release_version` = `0.1.0-beta.4` (or `0.1.0` for stable); `VERSION` must hold the core version. It runs the full
   suite and packages the universal app with that `RELEASE_VERSION`, the committed key and the committed feed. It
   checks the app's `GitHubPetReleaseVersion`, `CFBundleShortVersionString`, `SUPublicEDKey` and `SUFeedURL`, runs
   the render check and the Intel smoke on that very app, and uploads `GitHubPet-release-<version>` (ZIP +
   `.sha256`). The job summary records the commit, build number and SHA-256. A run from any other branch is marked
   TEST ONLY in the summary and must not be published.
2. **QA verifies** that artifact (its SHA-256 matches the summary).
3. **GitHub pre-release.** Create the release for the tag `v<release_version>` (the `release_version` from step 1, with a `v` in front) targeting **the commit in the summary** (mark betas as
   pre-release), which creates the tag there, and upload that artifact's ZIP and `.sha256` unchanged.
4. **Sign and publish the feed.** Chris downloads the same ZIP from the release and runs
   `scripts/release-appcast.sh v<release_version> <that zip>`. It refuses a ZIP whose app disagrees with the tag or the
   committed key, signs the ZIP with `sign_update` from the login Keychain (the script never reads the private key),
   and adds or replaces the item in `updates/appcast.xml`: enclosure = the GitHub Release asset URL,
   `sparkle:version` = `CFBundleVersion`, `sparkle:shortVersionString` = the release version, `sparkle:channel` =
   `beta` for prereleases, release-notes link = the GitHub release page. `sparkle:version` must keep increasing:
   the script refuses a build number that isn't newer.
5. **Appcast PR.** Open a PR with only the `updates/appcast.xml` change. Users see the update once it is on `main`.

`updates/appcast.xml` holds one item per published release. `scripts/test-release-appcast.sh` tests the script on
its own empty channel with a fake signer.

## Known limits

- Ad-hoc signatures change with every build, so macOS may treat an updated app as a new item for approvals. If you added GitHub Pet to Login Items
  yourself, check that entry after an update; in our tests these builds couldn't register a login item on their own.
- First install still needs Open Anyway; automatic update does not replace that.
- Anyone holding the production key can ship an update that installs without a Gatekeeper prompt.
- Builds before this feature (beta 1-3) have no updater: update them by hand once.
- The Beta 8 download is about 8 MB larger than Beta 7 (about 15 MB against 7 MB): about 6 MB is the animated pets' frames (#138; the
  mascot frames for both skins grow from 0.9 MB to 7.6 MB on disk), the rest the larger icon and binary. An update downloads the whole app.
- The Beta 7 to Beta 8 in-app update is first exercised by the Beta 8 release itself.
