# QA review: PR69 beta README RC 5e44a93 (claims and source)

**Claims and source review: PASS with two MED wording fixes.** The image check is deferred to t62's regenerated set, as PM asked, and no images were judged here.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task S from PM t61, 2026-11-16. No app was run.

## 1. Head, CI and scope

- **CI:** 43945427024 completed SUCCESS on exactly `5e44a93b9297b534d09489f7e4a6bed2b10703ba`.
- **Contains main:** the head contains current main `0b71732`.
- **After 49cdc0c:** only `docs/` and `scripts/` changed (images, the provenance README and `readme-screenshots.sh`).
- **Against main:** README, `SnapshotRenderer.swift`, `docs/development.md`, `docs/screenshots/beta/*` and `scripts/readme-screenshots.sh`.

## 2. SnapshotRenderer change

The new "settings full height" step renders `SettingsView` at 1400 pt in light and dark.

- **Demo row:** it temporarily sets `entitlementRepositories = ["example/pet-demo"]` (an invented Demo repo) and restores the saved list afterwards.
- **Snapshot launches only:** the code runs only in `--render-snapshots`. That mode is always forced onto `forcedSource = fixtures`, the in-memory `EphemeralDefaults` render-snapshots suite and `resetSettings`, regardless of `--defaults-suite`, so the `settings` save goes to throwaway memory.
- **Normal launches and the real domain:** unaffected.
- **`readme-screenshots.sh`:** uses an absolute-path throwaway suite, a gh trap, a check that it is a fixtures render, and per-image SHA-256 provenance.
- **INFO:** on its 600 s timeout the script sends `kill` to its own renderer PID. It is a developer tool, but QA runs it with that kill removed.

## 3. Images

Deferred to the regenerated set, per PM. PM has already sent t62 visual fixes: the Startup "not available" text, the Fixtures source, a privacy inconsistency, the very tall Settings image and the Simulator button. QA will re-verify artifact provenance (ZIP hash, revision), Demo-only content, light/dark consistency and match with the current UI on that set.

## 4. README claims checked against source

All of these are in the head: PR62 a3c93de, PR63 608adbe, PR64 f6790d3, PR65 4227c2a and PR66 9818b9d.

| Claim | Source | Result |
|---|---|---|
| Review requests and assigned issues on github.com; click opens it | `is:pr is:open review-requested:@me`, `is:issue is:open assignee:@me`; `SafeLink` | ✔ |
| Everything, or up to 10 selected orgs and repos; access checked; suggestions from the account | ScopeEditor max 10, validation, discovery | ✔ |
| Entitlement repositories marked with a key; never approves | PR65 | ✔ |
| Animation once per genuinely new item | InboxEngine | ✔ |
| Remembers across restarts | PR63 (seen items never re-announce; new while quit only if ≤24 h) | ✔ |
| Refreshes after wake; queued Refresh | PR66, **gh source only**, unit-tested only | ⚠ MED-2 |
| Honest states, including access-denied; hidden matches as a count | PR64, PR59 | ✔ |
| "Confirmed incidents" from githubstatus.com | the status feed includes unresolved "investigating" incidents | LOW-5 |
| Privacy mode on by default | `Settings.swift:48` | ✔ |
| "Quiet hours, snooze and Reduce Motion keep the mascot still" | only `effectiveReducedMotion` (Reduce Motion) stops the idle loop (`MascotView.swift:24-31`); quiet hours and snooze stop event animations and alerts, and the idle loop keeps playing | ✘ MED-1 |
| Open at login shows on, off or awaiting approval | PR62 (also "Unavailable") | ✔ |
| Custom packs through `GITHUB_PET_PACK_DIR`, validated, placeholder on failure | `LaunchOptions.swift:38`, PR55 | ✔ (LOW-3) |
| macOS 13+, universal | `build-app.sh` | ✔ |
| gh optional; Demo without it | `.fixtures` default | ✔ |
| Install: checksum, Open Anyway once per build, no Gatekeeper bypass | `docs/install.md` | ✔ (LOW-6) |
| No tokens | `TokenAccessSourceTests` (PR56) | ✔ |
| Read-only; "only validated github.com links are opened" | also opens validated **githubstatus.com** incident links (`AppModel.swift:623-631`) | LOW-4 |
| Local, no backend, no analytics | true; network is gh→github.com plus the public githubstatus.com API | ✔ (LOW-7) |
| Fixed error messages | every displayed failure is a constant string; no stderr text is displayed | ✔ |
| Limits: github.com only; 30 per category → partial; Open at login and Gatekeeper unverified; keyboard via menu bar and Settings, mascot not focusable, no live VoiceOver pass; workflow failures, deployments and own PRs not monitored | matches source and earlier QA | ✔ |
| No internal org names | only the public repo slug | ✔ |
| Links (`docs/design/README.md`, `provenance.md`, `install.md#2-check-the-download`, `readme-screenshots.sh`) | exist | ✔ |

## Polish verdict

**It reads as professional.** The pitch is clear and short, the beta notice is honest, and the privacy and safety section is concrete. The limits section names real gaps, and images and provenance are transparent. The tone is calm, with no marketing inflation, apart from the two items below.

**Fixes by severity:**

- **MED-1, inaccurate:** change "Quiet hours, snooze and Reduce Motion keep the mascot still while the inbox keeps updating" to something like "Quiet hours and snooze stop new-item animations and alerts; Reduce Motion keeps the mascot still. The inbox keeps updating."
- **MED-2, overpromise:** "It refreshes after your Mac wakes" applies to the GitHub CLI source only and is unit-tested only, never checked on a real sleep/wake. Add "(GitHub CLI source)" and list wake refresh under Limits as not yet verified on a real Mac, like Open at login.
- **LOW-3:** custom mascot packs need the app launched with an environment variable, which isn't possible from Finder. Call it an advanced or developer option (launch from Terminal) so beta users don't expect a Settings control.
- **LOW-4:** "only validated github.com links are opened" should read "github.com, and githubstatus.com for incidents".
- **LOW-5:** "Confirmed incidents" should be "Active incidents" or "Current incidents", because the feed includes ones under investigation.
- **LOW-6:** install step 1 doesn't say where the ZIP comes from. Say "from the latest successful `main` build's **GitHubPet-app** Actions artifact (needs a GitHub account)" until Releases exist, or link `docs/install.md#1-download`.
- **LOW-7 (optional precision):** under "Local", add "Network: only `gh` to github.com and the public githubstatus.com API."
- **INFO:** if the regenerated images show Demo "Workflow failure" rows, they contradict "Workflow failures … are not monitored yet". Either avoid them in README renders or caption them as Demo-only.
- **INFO:** "Remembers across restarts" could add "new items that arrived while it was quit are announced once (within 24 h)".
