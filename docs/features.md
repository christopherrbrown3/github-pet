# GitHub Pet features

The detail behind the [README](../README.md). Everything here describes the Beta 7 app. GitHub Pet is
read-only: every item opens on github.com, and nothing is approved, merged or changed from the app.

## The Inbox

Open it from the menu-bar icon or by clicking the pet.

- **Header.** Your chosen pet with a blue badge counting the items that need you, the source status and when the list last
  updated. Refresh and Settings sit on the right.
- **Tiles.** **Needs you** counts the items in the Needs you list (the same number as the badge), **Waiting on others** counts your pull
  requests and deployments that are waiting on someone else, and **GitHub status** shows the
  githubstatus.com status. Click **Waiting on others** to jump to its list.
- **Grouped rows.** Items are grouped by what they ask of you. Click a row to open it on GitHub.
- **Waiting on others.** Below the Needs you list, its own collapsed **Waiting on others** section
  lists those pull requests and deployments with its count. Expand it to see each one and why it
  waits: draft, review pending, checks running, checking for conflicts, or, for a deployment, approval by others or a wait timer. A row shows the first reason; hover it
  (or use VoiceOver) for all of them. These rows look quieter, never count in the badge, and never
  alert or notify.
- **Dismiss and Restore.** **×** removes an item from your Inbox on this Mac only; GitHub still
  has it. **View dismissed** lists saved dismissals, each with **Restore**. See [Using the Inbox](inbox.md).

### What appears

- **Review requests.** Pull requests waiting for your review. Choose in Settings whether to include
  requests to your teams or only reviews requested directly from you.
- **Assigned issues.** Open issues assigned to you.
- **Your pull requests that need you.** Changes requested, a merge conflict, failing checks, or
  approved and ready to merge (approved, not a draft, checks passing or none, and no conflict). The
  rest, including drafts and approved pull requests whose checks are running or that GitHub is still
  checking for conflicts, are listed under **Waiting on others** and never alert.
- **Entitlement approvals.** List the repositories where access requests arrive as pull requests, and
  their review requests get a key icon. GitHub Pet only opens the pull request.
- **Workflow failures (opt-in).** Failing GitHub Actions runs on the default branch of repositories you
  select. Failures you triggered are marked urgent.
- **Deployment approvals (opt-in).** Runs in repositories you select that wait for a deployment you can
  approve. The row opens the run; runs waiting for other reviewers or a timer are listed under
  **Waiting on others**.
- **GitHub service incidents.** Active incidents from the public githubstatus.com feed, kept apart
  from your own items.

### Honest states

Loading, partial, stale, signed out, rate limited, access denied and failed results are labelled as
such and never look like an empty Inbox. When a refresh fails, the last good list stays visible with
the time it was fetched. Matches GitHub counts but your account can't see are reported as a number.
**Waiting on others** follows the same rules: a partial result shows "at least" (for example `2+`), and
stale or failed data shows `?` with the last known rows marked as such, never "nothing waiting".
Error text from `gh` or GitHub is classified rather than shown, so it can't leak organization names.

## The desktop pet

- **Two skins.** **Mona** (default) and **Little Chris**, chosen in Settings → Mascot. The choice is
  saved.
- **Calm by default.** A short animation plays once for a genuinely new item, not on every refresh or
  after a reconnect. **Reduce motion** (or macOS's own setting) keeps the pet still.
- **Count badge and hover summary.** The badge shows how many items need you; hover for the newest.
- **Optional.** Hide the pet in Settings; monitoring and the Inbox keep working, and the menu-bar icon then
  shows the same count the badge would (`?`, `99+` and stale or partial rules included; nothing when
  there is nothing to count). While the pet is showing, the menu-bar icon has no count. The count sits
  beside the paw in a fixed-width slot, so the icon doesn't shift, and VoiceOver reads it with the status.
- **Remembers across restarts.** Items you've seen don't come back as new after a relaunch. Items that
  arrived while the app was quit are announced once (within 24 hours).
- **Custom packs (advanced).** Launch from Terminal with `GITHUB_PET_PACK_DIR` set to replace the
  artwork ([pack format](design/README.md)). Invalid packs fall back to the built-in art without
  affecting monitoring.

## Settings

Two panes.

- **Mascot.** Show or hide the pet, choose a skin, size, Reduce motion, reset position, and
  a button that opens Login Items (**Open at login** can't be switched on in
  these builds; see [limits](#known-limits)).
- **GitHub.** The `gh` connection and setup help, the data source (GitHub CLI by default, or invented
  Demo data by choice), what to watch (everything you can access, or the organizations and
  repositories you choose, access-checked before they apply), entitlement repositories, opt-in alerts for
  failing Actions runs and deployment approvals, and software updates.

### Monitoring scope

Under **Settings → GitHub → Monitoring scope**, **Everything accessible** watches everything your `gh`
account can see. Choosing **Selected organizations and repositories** opens a browser of your account,
the repositories shared with you, and your organizations, with repository counts. Search, filter and
sort, then tick repositories, or tick **All repositories** for an organization, which also covers
repositories added later. **Apply** checks access to every entry, then saves your choice. Reopen the
window with **Choose Repositories…**, or type an entry's name with **Add by Name…**.

- Up to 500 organizations and repositories. Long selections scroll and show how many more entries are
  below; entries that need fixing are listed first.
- When GitHub withholds a list (for example because of single sign-on), rate-limits the app, or your
  `gh` account is signed out or missing, the window says so and offers a next step. It never shows a
  false empty list.
- If GitHub can't read one organization you chose, the repositories you chose inside it are still
  checked on their own where possible, and the Inbox is marked partial.
- Large selections refresh more slowly: about 7 seconds for 100 entries and about 35 seconds for 500
  on one test machine, roughly double while a chosen organization can't be read.
- Accounts with an underscore in their name (enterprise managed users) are listed but can't be picked
  yet. If your own account is one, choose **Everything accessible**.

## Data source

New installs use your **GitHub CLI** (`gh`) account on github.com. If `gh` is missing or signed out,
the Inbox and Settings say so and link to setup steps. **Demo data** is invented, always labelled
DEMO, and appears only if you choose it under Settings → GitHub → Source.

## Updates

Anyone on Beta 3 or earlier installs by hand once; Beta 4 and later get updates in the app, delivered by
[Sparkle](https://sparkle-project.org). Automatic checks are on unless you turned them off (an earlier choice is kept; Settings
can turn them off): about every 6 hours, plus after launch and wake when a check is due. An available update shows a
dot on the menu-bar icon, an "Update available" banner in the Inbox header (Update… or Later) and a quiet "Version X
available" line in the menu; it asks before installing, unless you turn on automatic installs. Updates
are verified with an EdDSA signature before they're unpacked. See [Updates](updates.md).

## Privacy and security

- No tokens are requested, read or stored; all GitHub access goes through your installed `gh`.
- No backend and no analytics. Settings, entitlement repositories, seen items and dismissals stay on
  your Mac.
- Network use: `gh` talking to github.com, the public githubstatus.com API, the update feed
  (raw.githubusercontent.com) and update downloads from GitHub Releases.
- Only validated links open: github.com, and githubstatus.com for incidents.

## Known limits

- **In-app updates work from Beta 4 onward.** Beta 5 and Beta 6 were delivered that way. Earlier
  betas install by hand.
- **Intel.** The app is universal (Apple Silicon and Intel). The Intel half is checked in CI under
  Rosetta, not on Intel hardware.
- **Not notarized.** Ad-hoc signed builds need **Open Anyway** on first launch
  ([installation guide](install.md)).
- **Open at login** isn't available on ad-hoc signed builds. A button in Settings → Mascot opens
  Login Items in System Settings so you can add GitHub Pet yourself.
- **Hidden in this beta.** Privacy mode, snooze and quiet hours are hidden to keep things simple.
  Settings saved by an earlier beta are kept but have no effect until those features return, so
  repository names and titles are shown.
- **github.com only.** GitHub Enterprise Server isn't supported.
- **Search caps.** Search returns at most 30 items per category for each group of up to 50 selected
  entries; reaching that marks the result partial. Deployment approvals read up to 10 waiting runs per repository.
- **"Checks failing"** means any failing check on the latest commit; GitHub's search can't say which
  checks are required.
- **Announcements.** A merge conflict is announced at most once per pull request; failing checks once
  per new failing commit; approved and ready to merge once per ready commit (GitHub rechecking
  conflicts on the same commit doesn't announce it again).
- **"Approved, ready to merge"** uses GitHub's review decision, all checks on the latest commit and its
  conflict check. GitHub's search can't say whether branch protection needs more, such as more
  approvals than your repository's rule, so the pull request page has the final say.
- **Actions alerts** cover only selected repositories, and only the default branch's latest commit.
  Changing coverage or the monitoring scope re-baselines quietly: items first seen then aren't
  announced. Actions items aren't remembered across a relaunch.
- **Not verified by hand yet:** refresh after a real sleep and wake, keyboard and VoiceOver use of the
  new Inbox, Reduce Motion, hover, the app icon in Finder and the Dock at small sizes, and every
  supported macOS version. The floating pet isn't keyboard focusable; use the
  menu-bar icon.
