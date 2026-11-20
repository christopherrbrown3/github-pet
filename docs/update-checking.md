# Update checking (#90, phase 1)

Check, show release notes, and open the GitHub release page. Nothing is downloaded or installed
by the app; automatic installation is pending trusted distribution (#89). The app never touches
quarantine or Gatekeeper.

## How it works

- `UpdateChecker` (GitHubPetCore) GETs `https://api.github.com/repos/christopherrbrown3/github-pet/releases?per_page=30`
  over the hardened `URLSessionStatusTransport` (ephemeral, no cookies/credentials, redirects refused,
  1 MiB cap, https + host allow-list). Unauthenticated: no `gh`, token or account. `/releases/latest` is not used.
- Drafts are ignored. A release is trusted only if its tag is `vMAJOR.MINOR.PATCH[-pre][+build]`, GitHub's
  `prerelease` flag agrees with the tag, and its `html_url` passes `SafeLink` and lives under this repository's
  `/releases/`. If releases exist but none are trusted the check **fails** (malformed); it never reads as up to date.
- Versions compare by SemVer 2.0 precedence (`0.1.0-beta.3 < 0.1.0-beta.10 < 0.1.0`); a numeric `+N` build
  only breaks ties between equal versions.
- Errors: offline, timeout, rate limited (429, or 403 with an exhausted quota or `Retry-After`, with the reset
  time from `x-ratelimit-reset`/`Retry-After`), other HTTP statuses, malformed/untrusted metadata, oversized replies.

## Channel and installed version

`VERSION` and `CFBundleShortVersionString` are `MAJOR.MINOR.PATCH` only, so a Beta build reports `0.1.0`;
the prerelease lives only in the tag (`v0.1.0-beta.N`). Release builds should be made with

    RELEASE_VERSION=0.1.0-beta.4 scripts/build-app.sh release --universal

which adds `GitHubPetReleaseVersion` to Info.plist (it must extend `VERSION`). **Stable is the default
channel for every build** and Beta is an explicit opt-in (Sparkle's model), so a check never moves anyone to a
prerelease. A beta or untagged build on Stable is told in Settings that every release so far is a beta and to choose
Beta to be notified. An untagged build (every build before this key, plus local/CI builds) whose
`GitHubPetSourceRevision` matches a release's `target_commitish` counts as that release; otherwise it is treated
as older than every release of its version. The user's own channel choice always wins and is stored separately
from `PetSettings` (`update.channel`, `update.autoCheck`, `update.lastCheck`).

The release workflow should pass `RELEASE_VERSION` (follow-up for whoever cuts releases; this PR does not release).

## Replacing the checker later

The UI and `UpdateModel` depend only on the `UpdateChecking` protocol (`check(installed:channel:)` returning
`UpdateCheckResult` or `UpdateCheckError`), the channel enum and the update-state model. A Sparkle-backed
implementation can replace `UpdateChecker` without touching the views. No Sparkle dependency, appcast or key
handling exists here.

## Periodic check

On launch and hourly the model checks whether 24 hours have passed since the last attempt (success or failure) and,
if the toggle is on, runs one silent background check. Only a normal launch ever uses the network; QA, snapshot,
simulated and custom-defaults launches use fixtures. The inbox, its badge and the mascot are untouched.

## QA scenarios (no network)

`GitHubPet --simulate-monitoring-scope --qa-scenario <name> --qa-output <dir>`; the fixture installed build is
`0.1.0-beta.3 (build 200)`. Each step record gains an `updates` object (status, summary, channel, installed,
lastCheck, version, publishedAt, notes, releaseURL, error, errorMessage, rateLimitResetAt, downloadOpened).
Rate-limit fixtures reset at `2026-11-21T00:00:00Z`.

| Scenario | Shows |
|---|---|
| `updates-no-update` | up to date |
| `updates-available-beta` | 0.1.0-beta.4 on Beta, Settings section PNG, Download records the release URL |
| `updates-available-stable` | 0.1.0 on Stable, Download |
| `updates-channel-switch` | same beta release: Stable says up to date, Beta offers it |
| `updates-drafts-only` | a draft is ignored: up to date |
| `updates-errors` | offline, 403, rate-limited 403, rate-limited 429 (with reset), malformed JSON, untrusted metadata, HTTP 500 |
| `updates-all-states` | every fixture in turn |

Actions for custom scenarios: `update-check` (`fixture`: no-update, beta-available, stable-available, drafts-only,
offline, forbidden-403, rate-limited-403, rate-limited-429, malformed, untrusted-metadata, server-error-500; optional
`channel`), `update-auto-check` (`on`), `update-download`, `open-updates` (renders the section).
