# QA report: PR #99 Sparkle 2 auto-update (#90)

- Reviewed head: `b7676483c8259bfd099482b2746bcf3c67fe1627` (branch `feat/90-update-check`), CI run 44773169054: success.
- Base at review: main had moved (PR #97 merged, 7ed30cc); GitHub reports the PR **CONFLICTING / DIRTY** (see D1).
- Host: macOS 27.0 (26A428), Swift 6.2.3, Apple silicon, admin account. QA by qa-engineer-2, 2026-11-20.
- Method tiers: S (source), A (real built apps, real Sparkle UI driven with System Events clicks and screenshots). Test rig: scratch clone at the exact SHA, nothing under the real `dev.github-pet.GitHubPet` domain; the running Beta.2 (pid 25988) was not touched.

## Verdict

**PASS on b767648 for the QA scope that was run, with one required follow-up (D1) and the limitations below.** Not mergeable until main is merged into the branch and the Settings placement is re-checked.

## Rig

| Item | Value |
|---|---|
| Build N | VERSION 0.1.0, CFBundleVersion 279, ad-hoc, `BUNDLE_ID_SUFFIX=.qaspk99`, `SPARKLE_FEED_URL=http://127.0.0.1:8123/appcast.xml`, `SPARKLE_PUBLIC_KEY_FILE` = QA key. Main binary SHA-256 `17ed37b7…cb9` |
| Build N+1 | VERSION 0.1.1, build 280 (scratch commit on top). Main binary SHA-256 `33536910…d3d` |
| Beta build | N with `RELEASE_VERSION=0.1.0-beta.8` |
| QA public key (throwaway, Keychain account `github-pet-qa`) | `shK5V215eN3dhg2mn3MNJZQY7Ma7VDfLeVUTMGxLQPM=` |
| Wrong key (account `github-pet-qa-wrong`) | `DL5BOHTL13Zri8TP1GwSZ0ZHcpsnLaJIlL9RcOuxIlI=` |
| good.zip / unsigned.zip | `c60491db97e5f201c17fd8f972ec1cd5b172fe9ac22ed22617b56ffb0fa96ee8` |
| tampered.zip (one byte flipped after signing) | `508f6c25c0cea088d6388122f98409226e7aca7056b2c82737ff8fb49546ff0b` |
| Feed | python `http.server` on 127.0.0.1:8123, per-request log with headers |

The production key and default Keychain account (`ed25519`) were never used. Both QA Keychain items were deleted at the end and confirmed gone. (One compound command that also queried the default account was blocked by the harness before it ran; it was my mistake and is disclosed to t6f.)

## Results

| ID | Result | Evidence |
|---|---|---|
| UPD-01 | PASS | Settings shows `Installed 0.1.0 (build 279)` / `0.1.1 (build 280)`, Last checked, "Check for Updates…" in the menu and Settings. |
| UPD-02 | PASS (UI) | Sparkle consent prompt "Check for updates automatically?" appears on second launch; its "Automatically download and install updates" box is unchecked and the text does not promise silent installs. Update dialog shows release notes, Skip / Remind / Install Update. See D2 for one unexplained default write. |
| UPD-03 | PASS | Malformed feed: "An error occurred while parsing the update feed." HTTP 404: "An error occurred in retrieving update information." Neither reads up to date. Valid empty feed reads "You're up to date" (see N3). |
| UPD-04 | PASS | N→N+1 succeeded three ways: (1) opt-in silent mode, verified staging then installed on quit; (2) user-confirmed from `~/Applications/GitHubPetQA` (dialog → Install Update → "Ready to Install", **bundle still 279 until Install and Relaunch was clicked**, then 280 relaunched at the same path); (3) user-confirmed from `/Applications`. Bundle ID unchanged. |
| UPD-05 | PASS | Tampered, wrong-key and unsigned archives each end in "Update Error! The update is improperly signed and could not be validated." Installed binary SHA unchanged (`33536910…`), version 280, `~/Library/Caches/…/org.sparkle-project.Sparkle/{Installation,PersistentDownloads}` empty afterwards. Mismatched `length` with a valid signature is **not** rejected (Sparkle's signature covers the bytes; `length` is advisory). That is expected, see N4. |
| UPD-S06 | PARTIAL | (a) `/Applications` PASS. (b) `~/Applications` PASS. A scratch `/private/tmp` path also PASS. (d) translocated/quarantined first launch: Gatekeeper "GitHubPet Not Opened" shown for a quarantined N (screenshot, dismissed with Done); Open Anyway was not exercised (changes system security state). Root-owned/non-writable folder: NOT RUN. **(c) non-admin: NOT RUN (deferred by Chris 2026-11-20); listed as a known limitation, not a pass.** |
| UPD-07 | PASS | Seeded: Little Chris, 160 pt, mascot position, reduced motion, privacy off, snooze until 2026-12-31, quiet hours 23:00–06:00, scope repo `qa-org/qa-repo`, workflow-failure watch on, one dismissed item. `defaults export` before vs after update and after relaunch: identical except `event-baseline.lastSuccess` advancing (digests and `baselineEstablished` unchanged, no replay), `SULastCheckTime`. Inbox showed badge 2 and the dismissed row hidden after relaunch. |
| UPD-08 | PARTIAL | Open at login reads "Unavailable. macOS can't register this copy of GitHub Pet. Move it to Applications and try again." for the ad-hoc QA build in `/private/tmp`, `~/Applications` and `/Applications`, before and after update (truthful, never a stale "on"). The enabled / requires-approval states could not be produced, so the post-update transitions are unverified. See N2. No login item was registered and none exists in BTM for the QA bundle. |
| UPD-09 | PASS (limited) | Quarantine xattr set on N, update installed by Sparkle: new app has **no** `com.apple.quarantine`, `codesign --verify --strict --deep` valid, relaunched with no Gatekeeper prompt. `spctl -a -vv` reports `rejected` before and after (expected for ad-hoc). The first-launch Open Anyway flow and a manual re-download prompt were not exercised. |
| UPD-10 | PASS | Beta-tagged item vs stable build, default channel: no offer, "up to date". Same item with `update.betaOptIn` on: offered. Prerelease build (`GitHubPetReleaseVersion=0.1.0-beta.8`): offered with no opt-in. Not run: "newer stable beats beta" ordering (Sparkle behaviour). |
| UPD-11 | PASS (A) | Equal build (279) and older build (270) items: "You're up to date" and no downgrade offered. Unit tests are developer-owned and green in CI (`SemanticVersion`/`UpdatePolicy`). |
| UPD-12 | NOT RUN | Kill mid-download/extract/install (best effort) not attempted. |
| UPD-13 | PASS (limited) | Update UI never touched the inbox badge or counts; update dialogs are Sparkle's own windows; no gh child process under the app. Scheduled-check quiet menu line not observed (checks were user-initiated or install-on-quit). |
| UPD-14 | PASS | Feed log: only `GET /appcast.xml` then the archive, `User-Agent: GitHub Pet/0.1.0 Sparkle/2.10.1`, no query string, no Authorization header, no profile parameters; `SUEnableSystemProfiling` absent, `SUSendProfileInfo` = 0. App process had no gh children. |
| UPD-15 | PASS | `Sparkle.framework` in `Contents/Frameworks` with symlinks; no `*.xpc`; rpath `@executable_path/../Frameworks` in `otool -l`; Autoupdate, Updater.app, framework and app each `Signature=adhoc`; `codesign --verify --strict --deep` valid. Info.plist: `SUFeedURL`, `SUPublicEDKey` (QA build), `SUAutomaticallyUpdate=false`, `SUAllowsAutomaticUpdates=true`, `SUScheduledCheckInterval=86400`, `SUVerifyUpdateBeforeExtraction=true`; no `SUEnableSystemProfiling`. `Package.swift` pins `exact: "2.10.1"`, `Package.resolved` 2.10.1. Default-config build (only the bundle suffix changed): `SUFeedURL` = committed URL, **no `SUPublicEDKey`**, Settings: "Updates not configured. Updates aren't set up in this build yet: it has no update signing key.", menu row "Updates not configured" with the check button disabled. `git grep` finds no private key material; the committed key file has no key; the fixture key is test-only. |
| UPD-16 | PASS | docs/updates.md and docs/install.md match what ran: first install needs Open Anyway, EdDSA is the trust root, Sparkle clears quarantine on installed updates, key loss means manual reinstall, #89 is post-beta, no notarization claim, no instruction to disable Gatekeeper. |
| UPD-17 | PASS | No write verbs or token/Authorization code added; the update path has no `gh`, `Process` or environment/launch-argument override (`UpdateController.swift`, `UpdatePolicy.swift` read only `Info.plist` and `UserDefaults`). Overrides exist only in `scripts/build-app.sh` with validation (bad suffix, non-local http, query string, malformed key rejected; proven by `test-update-build.sh`). |

Other commands (this checkout, merged with the PR head): `swift build` exit 0; `scripts/test.sh` 633 tests, 1 failure, `descendantHoldingThePipeDoesNotLeakReadsOrDescriptors` (fd count 6 vs 5, ProcessRunner/GitHubCLITests, untouched by the PR) which **passes when run alone** (flaky under the 260 s parallel load); `scripts/test-release-appcast.sh` exit 0 "release appcast checks passed"; `scripts/test-update-build.sh` exit 0 "update build checks passed".

## Defects and findings

- **D1 (required, developer): PR conflicts with main.** PR #97 (Settings redesign, 7ed30cc) merged after the PR head; GitHub says CONFLICTING. `UpdateStatusSection` is mounted in the old single-page `SettingsView`; it must be re-homed in the new Mascot/Alerts/GitHub panes. Re-QA the delta after the merge.
- **D2 (low, unconfirmed): `SUAutomaticallyUpdate` became 1 after the consent prompt.** In the first launch I pressed Return on the consent prompt (the box was unchecked in the screenshot). Afterwards `defaults` showed `SUEnableAutomaticChecks=1` **and** `SUAutomaticallyUpdate=1`, and the next check downloaded silently. I could not rule out that my keystroke toggled the box. Repro for the developer: fresh `BUNDLE_ID_SUFFIX` domain, launch twice, click **Check Automatically** with the mouse without touching the checkbox, then `defaults read <domain> SUAutomaticallyUpdate`. Expected: absent or 0.
- **N1 (low UX):** with silent install on, a verified update waits until quit and neither the menu nor Settings says an update is ready.
- **N2:** Open at login is unavailable for ad-hoc builds even in `/Applications` on this Mac; the app's wording is truthful. Not a defect, but the post-update login transitions need a signed build to verify.
- **N3:** a reachable but empty feed reads "You're up to date" (correct: nothing newer exists). The committed `updates/appcast.xml` is empty, so after the key is added and before the first release this is what users see.
- **N4:** Sparkle ignores a wrong `length` when the EdDSA signature is valid; EdDSA remains the only trust root.
- **N5 (cosmetic):** the Sparkle dialog on a beta build says "you have 0.1.0" because it uses `CFBundleShortVersionString`; Settings shows `0.1.0-beta.8` correctly.

## Not verified / limitations

- **UPD-S06(c) non-admin: NOT RUN (deferred by Chris).** Root-owned/non-writable location: NOT RUN.
- Production key, production appcast URL and a real published release (maintainer-only); notarization (out of scope).
- Real Open Anyway flow, Gatekeeper behaviour on a quarantined N after approval, manual re-download prompt.
- UPD-12 kill/failure-injection cases; scheduled (unattended) check behaviour over 24 h; "stable beats beta" ordering.
- Open at login enabled/requires-approval states (see N2); real VoiceOver on Sparkle dialogs.
- Intel/x86_64 builds (rig was arm64 only).

## Cleanup

- Keychain items `github-pet-qa` and `github-pet-qa-wrong` (service `https://sparkle-project.org`) deleted and confirmed absent. Server on 127.0.0.1:8123 stopped. QA apps removed from `/Applications` and `~/Applications/GitHubPetQA` (the empty `~/Applications` folder existed before and was left in place).
- **Preference files left for Chris (not deleted by rule):** `~/Library/Preferences/dev.github-pet.GitHubPet.qaspk99.plist`, `~/Library/Preferences/dev.github-pet.GitHubPet.qaspk99nk.plist`. Also a cache folder `~/Library/Caches/dev.github-pet.GitHubPet.qaspk99`. The real `dev.github-pet.GitHubPet` domain was never touched.
