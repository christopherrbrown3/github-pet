# GitHub Pet features

The detail behind the [README](../README.md). Everything here describes the Beta 4 app. GitHub Pet is
read-only: every item opens on github.com, and nothing is approved, merged or changed from the app.

## The Inbox

Open it from the menu-bar icon or by clicking the pet.

- **Header.** Your chosen pet with a blue count badge, the source status and when the list last
  updated. Refresh and Settings sit on the right.
- **Tiles.** **Assigned** counts what's waiting on you, **Waiting** counts your pull requests that are
  waiting on others, and **GitHub** shows the githubstatus.com status.
- **Grouped rows.** Items are grouped by what they ask of you. Click a row to open it on GitHub.
- **Dismiss, Undo and Restore.** **×** removes an item from your Inbox on this Mac only; GitHub still
  has it. **Undo** reverses the last dismissal. **View dismissed** lists saved dismissals, each with
  **Restore**. See [Using the Inbox](inbox.md).

### What appears

- **Review requests.** Pull requests waiting for your review. Choose in Settings whether to include
  requests to your teams or only reviews requested directly from you.
- **Assigned issues.** Open issues assigned to you.
- **Your pull requests that need you.** Changes requested, a merge conflict or failing checks. The
  rest, including drafts and pull requests GitHub is still checking, are counted as waiting on others
  and never alert.
- **Entitlement approvals.** List the repositories where access requests arrive as pull requests, and
  their review requests get a key icon. GitHub Pet only opens the pull request.
- **Workflow failures (opt-in).** Failing GitHub Actions runs on the default branch of repositories you
  select. Failures you triggered are marked urgent.
- **Deployment approvals (opt-in).** Runs in repositories you select that wait for a deployment you can
  approve. The row opens the run; waits for other reviewers or a timer are only counted.
- **GitHub service incidents.** Active incidents from the public githubstatus.com feed, kept apart
  from your own items.

### Honest states

Loading, partial, stale, signed out, rate limited, access denied and failed results are labelled as
such and never look like an empty Inbox. When a refresh fails, the last good list stays visible with
the time it was fetched. Matches GitHub counts but your account can't see are reported as a number.
Error text from `gh` or GitHub is classified rather than shown, so it can't leak organization names.

## The desktop pet

- **Two skins.** **Mona** (default) and **Little Chris**, chosen in Settings → Mascot. The choice is
  saved.
- **Calm by default.** A short animation plays once for a genuinely new item, not on every refresh or
  after a reconnect. **Reduce motion** (or macOS's own setting) keeps the pet still.
- **Count badge and hover summary.** The badge shows how many items are unread; hover for the newest.
- **Optional.** Hide the pet in Settings; monitoring, the Inbox and the menu-bar icon keep working.
- **Remembers across restarts.** Items you've seen don't come back as new after a relaunch. Items that
  arrived while the app was quit are announced once (within 24 hours).
- **Custom packs (advanced).** Launch from Terminal with `GITHUB_PET_PACK_DIR` set to replace the
  artwork ([pack format](design/README.md)). Invalid packs fall back to the built-in art without
  affecting monitoring.

## Settings

Two panes.

- **Mascot.** Show or hide the pet, choose a skin, size, Reduce motion, reset position, and
  **Open at login** (see [limits](#known-limits)).
- **GitHub.** The `gh` connection and setup help, the data source (GitHub CLI by default, or invented
  Demo data by choice), what to watch (everything you can access, or up to 10 organizations and
  repositories, access-checked before they apply), entitlement repositories, opt-in alerts for
  failing Actions runs and deployment approvals, and software updates.

## Data source

New installs use your **GitHub CLI** (`gh`) account on github.com. If `gh` is missing or signed out,
the Inbox and Settings say so and link to setup steps. **Demo data** is invented, always labelled
DEMO, and appears only if you choose it under Settings → GitHub → Source.

## Updates

Beta 4 is installed by hand once. Later versions are delivered by
[Sparkle](https://sparkle-project.org): GitHub Pet checks at most once a day, shows a quiet "Version X
available" line in the menu and asks before installing, unless you turn on automatic installs. Updates
are verified with an EdDSA signature before they're unpacked. See [Updates](updates.md).

## Privacy and security

- No tokens are requested, read or stored; all GitHub access goes through your installed `gh`.
- No backend and no analytics. Settings, entitlement repositories, seen items and dismissals stay on
  your Mac.
- Network use: `gh` talking to github.com, the public githubstatus.com API and the update feed.
- Only validated links open: github.com, and githubstatus.com for incidents.

## Known limits

- **Not notarized.** Ad-hoc signed builds need **Open Anyway** on first launch
  ([installation guide](install.md)).
- **Open at login** isn't available on ad-hoc signed builds. A button in Settings → Mascot opens
  Login Items in System Settings so you can add GitHub Pet yourself.
- **Hidden in Beta 4.** Privacy mode, snooze and quiet hours are hidden to keep things simple.
  Settings saved by an earlier beta are kept but have no effect until those features return, so
  repository names and titles are shown.
- **github.com only.** GitHub Enterprise Server isn't supported.
- **Search caps.** Each search returns at most 30 items per category; reaching that marks the result
  partial. Deployment approvals read up to 10 waiting runs per repository.
- **"Checks failing"** means any failing check on the latest commit; GitHub's search can't say which
  checks are required.
- **Announcements.** A merge conflict is announced at most once per pull request; failing checks once
  per new failing commit.
- **Actions alerts** cover only selected repositories, and only the default branch's latest commit.
  Changing coverage or the monitoring scope re-baselines quietly: items first seen then aren't
  announced. Actions items aren't remembered across a relaunch.
- **Not verified by hand yet:** refresh after a real sleep and wake, keyboard and VoiceOver use of the
  new Inbox, and every supported macOS version. The floating pet isn't keyboard focusable; use the
  menu-bar icon.
