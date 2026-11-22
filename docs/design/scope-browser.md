# Monitoring scope browser (#137)

Designer review and interaction spec for replacing the type-in organization and repository picker
(Settings › GitHub › Monitoring scope) with a browser. Mockups are in
[`scope-browser/`](scope-browser/), light and dark, drawn with invented demo names only
(`demo-user`, `example-org`, `harbor-demo`, `lumen-labs`, `tidewater-demo`, `quiet-meadow`,
`partner-sso-demo`). They are static SwiftUI layouts rendered offscreen by
[`scope-browser/mockups.swift`](scope-browser/mockups.swift), a throwaway script outside `Sources`
(see [Reproducing the images](#reproducing-the-images)). They show layout and copy. They are not
pixel specs: the real build uses native `List`, `Toggle` and `.searchable` controls.

## 1. Usability review of the current picker

Evidence: `MonitoringScopeSection.swift`, `ScopeEditor.swift`, `ScopeEditing.swift`, and the
offscreen renders from `scripts/render-check.sh` on `main` at 5902689
([`current/settings-scope-long.png`](scope-browser/current/settings-scope-long.png),
[dark](scope-browser/current/settings-scope-long-dark.png): the 10-entry Demo draft with errors).

| # | Heuristic | Problem | Severity |
|---|---|---|---|
| 1 | Recognition over recall | The main path is typing an exact `login` or `owner/name` into blank fields. The only aid is three steps away: **Find suggestions**, then a flat **Organizations** or **Repositories** pull-down, then a pick. The menus can't be searched, show nothing but names and can't be browsed by owner. | High |
| 2 | Large accounts | Discovery (`ScopeDiscoveryPagePlan`) fetches at most 3 × 50 repositories from `viewer.repositories` in GitHub's affiliation order. On a large real account (thousands of affiliated repositories; one organization with several thousand), the menu shows a small fraction of what the user can read, in an order the user can't predict, with no search to find the rest. "first 150 shown (limit reached; more exist)" is a caption the user is unlikely to read. | High |
| 3 | Context and the selection at a glance | A chosen entry is an editable text field. Nothing shows the owner, whether it's private, archived or a fork, or when it was last pushed. The selection looks the same as the input. Editing a chosen row in place invites typos, and ten repeated **Remove** text buttons add noise. | High |
| 4 | Feedback and error states | Three or four caption lines stack under the controls with no hierarchy ("Suggestions not loaded.", "Account not verified yet…", the limit message, the status). The limit message appears twice. When discovery fails or is denied, the menus are disabled in the same way as an empty result, and the reason is only in a caption. Visually, that is the "looks like no repositories" case AGENTS.md rules out. | High |
| 5 | Constraints and org vs. repository meaning | The 10-entry cap (`MonitoringScope.maximumTargets`) is invisible until you hit it: there's no counter. The UI never says that an organization entry covers every repository, including future ones, or that it uses one slot where ten repositories use ten. Adding `org` plus `org/repo` is silently redundant. | Medium |
| 6 | Discoverability of preconditions | **Find suggestions** is disabled until the account is verified ("Refresh the Inbox"). The reason is only in a VoiceOver hint and a caption further down, and nothing in Settings does the refresh. | Medium |
| 7 | Placement | Everything is inline in a 520 pt grouped Form inside a pane about 1,500 pt tall. With a long draft, Cancel and Apply sit in the middle of the scrolling pane, between Sources and Review requests. | Medium |
| 8 | Keyboard and VoiceOver | Suggestion menus with up to 150 items are read one by one and have no type-to-filter. When a menu is empty, its hint is the whole discovery summary sentence. Each draft row is a text field plus a Remove button, which doubles the tab stops (24 for a 10-entry draft, counting both Add fields and buttons). The good parts to keep: announcements through `ScopeEditor.report`, labelled errors, and a single spoken name per field. | Medium |
| 9 | Error prevention | Inline errors only describe the format ("letters, digits and hyphens…"). A typo is found only on Apply, where it's reported as "Not found, or this account cannot read…". | Low |

## 2. Research

### What gh can give cheaply

All of these go through `gh api graphql --hostname github.com`, under the same rules as today:
argument arrays, a viewer check on every page, and a 20 s / 2 MiB `CommandBudget`. Checked with gh
2.102.0. Only counts and costs were recorded.

| Need | Query | Notes |
|---|---|---|
| Organizations you belong to, with repository counts | `viewer { organizations(first: 100) { totalCount pageInfo nodes { login repositories { totalCount } } } }` | One page covers almost everyone. Counts let the sidebar show size before anything is loaded. Measured cost: 1 point. |
| Repositories per organization, newest activity first | `organization(login: $o) { repositories(first: 100, after: $c, orderBy: {field: PUSHED_AT, direction: DESC}) { totalCount pageInfo nodes { name nameWithOwner isPrivate isArchived isFork pushedAt } } }` | **The maximum page size is 100.** `first: 101` returns `EXCESSIVE_PAGINATION`. Several organizations × 100 repositories in one request still cost 1 point. |
| Your own repositories | `viewer { repositories(first: 100, ownerAffiliations: [OWNER], orderBy: …) }` | Same row fields. |
| Shared with you | `viewer { repositories(first: 100, affiliations: [COLLABORATOR], ownerAffiliations: [COLLABORATOR], …) }` | Repositories of owners you're not a member of. Group them by owner. |
| Server-side search for big owners | `search(type: REPOSITORY, query: "org:$o $term in:name fork:true", first: 50) { repositoryCount nodes { ... on Repository { … } } }` | Measured cost: 1 point. Run it only on an explicit action (a row or Return), not on every keystroke: search has secondary limits. Omit `archived:` to include archived repositories, and add `fork:true` to include forks. |
| Rate-limit reset time | `rateLimit { remaining resetAt }` in any query | Makes "resumes after 14:05" possible without parsing stderr. |
| Avatars | `avatarUrl` | **Don't fetch avatars.** The image is a separate HTTPS request outside gh, which breaks the "every GitHub operation via gh" rule. Use a coloured monogram derived from the login instead (see the mockups). |

SAML/SSO: an organization whose SSO session isn't authorized returns `FORBIDDEN` errors and null
nodes for its repositories. `GhFailure.deniesAccess` and the existing parser path already classify
this as access denied. Its sidebar row still appears, because membership is listed.

**Today's discovery** (`ScopeDiscovery.run`): one combined query per page with organization and
repository cursors, at most 3 pages × 50, sharing one budget. Each category gets a
`ScopeDiscoveryCompletion` (`exhausted`, `capped`, `partial` or `failed`), and a viewer mismatch
discards everything. The browser keeps every one of those rules. It changes what is fetched
(per-owner pages of 100, ordered by push) and when (lazily, as the user opens an owner).

### Libraries vs. native SwiftUI

Candidates I looked at (SwiftPM, macOS 13+):

| Option | What it gives | Problems |
|---|---|---|
| [ChimeHQ/Outline](https://github.com/chimehq/outline) | SwiftUI wrapper for `NSOutlineView` with lazy children | No checkbox or tri-state column. Lazy children is the only feature we'd use, and per-owner paging already covers it. |
| [sameesunkaria/OutlineView](https://github.com/sameesunkaria/outlineview) | `NSOutlineView` wrapper, row animations | No multi-select checkboxes. Adds an AppKit bridge that our `AccessibilityTreeTests` would then have to cover. |
| [SwiftlyUI](https://github.com/swiftly-developed/swiftlyui) SearchableMultiPicker | Search plus multi-select | A broad component kit. Its macOS support and canonical repository are unclear, and the controls look iOS-like. |
| [orchetect/SwiftUITokenField](https://github.com/orchetect/SwiftUITokenField) | `NSTokenField` wrapper | Chips for the summary only. Native `NSTokenField` VoiceOver support is weak. |
| Native SwiftUI | `List` with checkbox `Toggle`s, `.searchable` (macOS 12+), `NavigationSplitView` (macOS 13), `.sheet`, `ProgressView`, `ContentUnavailableView`-style empty states (built by hand: that API is macOS 14) | Hierarchical `Table` and the `.isToggle` accessibility trait need macOS 14, so we use `List` rows and a `Toggle` element instead. |

**Recommendation: native SwiftUI, no new dependency.** Reasons:

1. None of the libraries does the hard part: tri-state org/repo selection, a long scrolling selection,
   server search and our failure states. We would wrap a library and still write all of that.
2. Native `List`, `Toggle(.checkbox)` and `.searchable` give the system keyboard, type-select,
   focus ring and VoiceOver behaviour for free. They also stay inside what `AccessibilityTreeTests`
   already inspects.
3. The scale problem is solved by fetching lazily and searching on the server, not by a faster view.
   One owner page holds at most 100 rows, and plain `List` is comfortable at a few thousand.
4. The package has one dependency (Sparkle, pinned exactly). A small UI library is a lasting
   licence, maintenance and supply-chain cost for little gain.

If profiling ever shows `List` struggling (it shouldn't below about 5,000 loaded rows), ChimeHQ/Outline
(BSD-3-Clause) is the fallback to evaluate.

## 3. Design

### Where it lives

- **Settings section stays, simplified** ([01](scope-browser/01-settings-section.png),
  [dark](scope-browser/01-settings-section-dark.png)): Account, the Monitor radio group, then for
  *Selected* a read-only **Selected · N** list that scrolls, with an edge fade and an "N more" count while entries are out of view. Each row has a monogram, the name, a kind
  label ("All repositories", "Repository", "added by name") and a remove (⊖) button. Below it are
  **Choose Repositories…** and **Add by Name…**, then one status line plus Cancel and Apply. The
  editable text-field rows and the suggestion menus are removed.
- **Choose Repositories… opens a sheet** on the Settings window: 780 × 540 pt, resizable, minimum
  640 × 460. A sheet rather than inline, because browsing needs width (owner list plus repository
  list), it's a modal task with a clear commit (HIG: sheets for focused, dismissible tasks), and the
  520 pt Form can't hold a two-pane browser. Not a popover: popovers dismiss on outside clicks and
  are too small for hundreds of rows.

### Sheet layout ([02](scope-browser/02-browse-organization.png), [dark](scope-browser/02-browse-organization-dark.png))

- **Title** "Choose Repositories to Monitor", with the GitHub CLI account on the trailing side, so
  it's clear whose repositories these are.
- **Toolbar row**: a search field (focused when the sheet opens) and two menus: **Filter** (Hide
  archived is on by default, Hide forks is off) and **Sort** (Recently pushed is the default, Name
  is the alternative).
- **Sidebar** (`NavigationSplitView` sidebar or a `List` with `.listStyle(.sidebar)`):
  - **Selected · N**: a review list of everything chosen
    ([05](scope-browser/05-selected-review.png)).
  - *Your account*: `login (you)` and **Shared with you**.
  - *Organizations*: one row per organization, with a monogram, the login, a trailing repository
    count, and a status badge: ✓ (all repositories selected), a count capsule (N repositories
    selected), a lock-warning (access denied) or a small spinner (loading).
- **Detail pane** for the selected owner:
  - A header with monogram, name and "240 repositories · organization".
  - The **All repositories in {org}** card: a checkbox, with "Includes repositories added later.
    As one entry." Organizations only; your own account and Shared with you have no all option,
    because the model only supports organization targets.
  - A **REPOSITORIES** caption, with a trailing note such as "1 archived hidden".
  - Rows (26 pt): checkbox, a private (lock), public (book) or fork glyph, the name (archived names
    in secondary colour plus an **Archived** tag), a **Fork** tag, and the trailing relative
    pushed time ("2 hours ago").
  - A footer line: "Showing all 38", or "Showing the 100 most recently pushed of 240" with
    **Load 100 More**.
- **Sheet footer**: an **N selected** capsule, **Add by Name…**, then
  **Cancel** and **Apply** (the default button).

### Selection rules

- Checking a repository adds a repository target to the draft. Checking **All repositories** adds
  an organization target ([03](scope-browser/03-all-repositories.png)). That organization's
  individually checked repositories are then removed from the draft, because they're redundant, and
  the change is announced. Its rows show a dimmed checked box ("Included by All repositories").
- Unchecking **All repositories** returns the rows to unchecked. Previous individual picks aren't
  restored, which keeps the behaviour predictable.
- **Nudge**: when three or more repositories of one organization are checked, show the tip
  "Picking several here? 'All repositories' covers every repository in {org}, including new ones." Never switch
  automatically.
- **No product cap** (Chris, 2026-11-22). Checkboxes are never disabled for count. The Selected
  lists scroll (lazy rows, smooth at hundreds of entries) with a bottom edge fade and an
  **"N more"** count while entries are out of view. GitHub's per-request limits set a technical
  ceiling of 500 entries (`MonitoringScope.maximumTargets`, engine #140); the 501st is refused
  with the `ScopeRowProblem.overLimit` copy: "GitHub limits how much each check can look up, so
  GitHub Pet watches at most 500 organizations and repositories. To watch more repositories,
  choose their whole organization: it counts once and covers every repository in it."
- **Commit**: the sheet edits the same `ScopeDraft` the Settings section shows. **Apply** runs
  `ScopeEditor.apply()` (the existing validation) with an inline "Checking access…" spinner in the
  footer. On `.verified`, the sheet closes and Settings shows "Monitoring scope applied: …". On
  `.rejected`, the sheet stays open and switches to **Selected**, where each failed entry has an
  inline `ScopeRowProblem` message. **Cancel** restores the draft as it was when the sheet opened.
  This turns today's two-step edit-then-Apply into one place to commit, and it reuses all the
  existing guards.

### Search ([04](scope-browser/04-search.png), [dark](scope-browser/04-search-dark.png))

- Typing filters **loaded** rows immediately, as a case-insensitive substring match on
  `owner/name`. Results are grouped by owner, and a scope bar switches between **All owners** and
  the current owner.
- Search also matches organization names in the sidebar.
- For every owner that isn't fully loaded, a **Search GitHub for "term" in {owner}** row appears,
  showing "100 of 6,500 loaded". It runs the server search on click or Return. Results merge into
  that owner's rows with a "From search" caption.
- No matches (state 8) is never presented as empty. It says how many repositories haven't been
  loaded yet and offers the server search plus **Add by Name…**.

### Add by Name fallback ([06](scope-browser/06-add-by-name.png))

This is for organizations or repositories that GitHub doesn't list (SAML/SSO, an outside
collaborator on a private repository, or renamed repositories). It's a small sheet with one field
that accepts `login` or `owner/name`. A live line under the field shows the detected kind using
`ScopeDraft.addProblem` (✓ "Repository · owner/name", or the existing format message). **Add**
puts the entry in the draft without a network call, the same as today. Apply still checks access.
Entries added this way show "added by name" in the Selected list. The fallback is reachable from
the Settings section, the sheet footer and every error state.

### States ([07](scope-browser/07-states.png), [dark](scope-browser/07-states-dark.png))

Every state names what is known, keeps loaded rows visible, and offers a next step. Only state 7
may say "no repositories", and only after a complete (`exhausted`) answer with zero rows and no
error.

| # | State | Source | Presentation |
|---|---|---|---|
| 1 | Loading | owner page in flight | Header and count are known. A spinner with "Loading the most recently pushed repositories…" over placeholder rows. The sidebar badge shows a spinner. |
| 2 | Capped | `.capped` / `hasNextPage` | Rows, plus "100 of 6,500 loaded. Search finds the rest." and **Load 100 More**. |
| 3 | Partial | `.partial` | A warning banner, "Incomplete list: N loaded, then GitHub stopped answering. More exist.", with **Retry**. Loaded rows stay selectable. |
| 4 | Rate limited | `ScopeAccessFailure.rateLimited` | A warning banner with the reset time from `rateLimit.resetAt` when known. Loaded rows stay usable, and Add by Name still works. Retry is disabled until the reset time. |
| 5 | Access denied | `GhFailure.accessDenied` / FORBIDDEN | An error banner: "GitHub withheld this list. Single sign-on or a token scope blocks it. Run gh auth refresh and authorize SSO, then Retry." **All repositories** stays enabled, because Apply verifies it, and **Add a Repository by Name…** is offered. The sidebar shows the lock-warning badge with "—" instead of a count. |
| 6 | Signed out / gh missing | `.signedOut` / `.ghMissing` | The whole detail pane is replaced by "Sign in to GitHub CLI to browse" (or "Install GitHub CLI"), with **Try Again** and **Add by Name…**. The Selected list is kept. |
| 7 | Truly empty | `.exhausted` with 0 rows | "No repositories you can read. GitHub returned a complete answer for {owner}." |
| 8 | No search matches | local filter | As described under Search. |
| 9 | Technical ceiling | 500 entries (`overLimit`) | No banner or disabled state; the refused add reports the `overLimit` copy in the footer status and is announced. |
| — | Account not verified | `identity == nil` | The sheet opens to a "Checking your GitHub CLI account…" state and runs the identity check itself (`fetchIdentity`) instead of telling the user to refresh the Inbox. |
| — | Identity changed mid-browse | `.identityMismatch` | All loaded rows are discarded and "The GitHub CLI account changed. Reloading for {new login}." is shown. Never mix accounts. |
| — | Demo | `isDemo` | A "Demo: invented organizations, checked offline" caption under the title. It uses fixture owners. |

### Large accounts

- Nothing is loaded until the sheet opens. Then one request fetches the organization list with
  counts and the first page of your own repositories.
- Each owner's first page of 100, sorted by most recent push, loads when the owner is first
  selected, or prefetches for the top 3 organizations by count. Further pages load only on **Load
  100 More**.
- Loaded pages are cached for the life of the sheet (keyed by viewer ID), so switching owners
  doesn't refetch. Closing the sheet drops the cache.
- One `CommandBudget` covers each request, not the whole sheet session. A failed page affects only
  that owner.
- Server search is per owner, 50 results, and only on explicit action.

### Keyboard

| Key | Action |
|---|---|
| (open) | Focus in the search field |
| ⌘F | Focus search |
| ↓ from search | Move into the detail list |
| Tab / ⇧Tab | search → filter/sort → sidebar → detail list → footer |
| ↑ ↓ in sidebar | Change owner; the detail list updates |
| ↑ ↓ in detail | Move between rows; type-select jumps by name |
| Space | Toggle the focused row's checkbox (the "All repositories" card is the first row) |
| ⌘A | Not used: selecting a whole page by accident is too easy to miss |
| Return | Apply (default button); on a "Search GitHub" row, runs that search |
| Esc / ⌘. | Cancel (clears the search field first if it has text) |

### VoiceOver

- Each repository row is **one element**: the checkbox `Toggle`, labelled with the full sentence
  "lantern-api, lumen-labs, private, pushed 2 hours ago", and valued checked or unchecked. Use a
  `Toggle` so its value is spoken, and don't add a separate `accessibilityLabel` on top of a Text
  label (per `AccessibilityTreeTests`: read once, not twice).
- An inherited row reads "checked, included by All repositories in example-org" and is disabled.
- Sidebar rows: "lumen-labs, organization, 38 repositories, 2 selected". For access denied:
  "tidewater-demo, organization, repositories hidden by GitHub".
- Announce through `ScopeEditor.report` and `postAnnouncement`, once per change: page loaded ("Loaded
  100 of 240 repositories for example-org"), the state banners, selection count changes ("5
  selected"), redundant picks removed, and the Apply outcome.
- Banners are a single combined element with their action button kept separate. The search field's
  label is "Search repositories and organizations".
- The status sentences must still contain no target names except in Settings and this sheet, which
  are explicit surfaces (same rule as today).

### Visual notes (HIG)

- Use system colours and materials only. Accent for checked boxes and selection, orange for warnings,
  red only for access denied and validation errors. Everything works in light, dark and Increase
  Contrast.
- Monograms: a 20 pt rounded square with a stable hue from the owner login, white initial. Every
  row of the same owner gets the same colour.
- Body text is 13 pt, captions 11 pt semibold secondary. Numbers use `monospacedDigit`.
- Relative dates use `RelativeDateTimeFormatter` (named style), with absolute dates after 6 months
  ("Mar 2024").
- Window-title capitalization for the sheet title and buttons ("Choose Repositories…", "Add by
  Name…", "Load 100 More"), with an ellipsis where more input follows.

## 4. What the developer can reuse

| Existing | Reuse |
|---|---|
| `ScopeDraft` (`add`, `remove`, `addProblem`, `problems`, `candidate`, `blockingMessage`) | The sheet's selection is the draft. Add a helper that removes repository rows covered by an organization row. |
| `ScopeEditor` (`apply`, `cancel`, the revision/identity/generation guards, `report`/`announce`, `offPool`) | Apply and validation are unchanged. Add a `snapshotDraft`/`restoreDraft` pair for sheet Cancel. |
| `ScopeDiscoveryPagePlan` and `ScopeDiscovery.run` | The pattern for the new per-owner plans: cursor validation (`cursor`), strict `boolean`, a viewer check on every page, `ScopeDiscoveryCompletion` mapped to states 2, 3 and 7. Extend it with an owner parameter, `orderBy: PUSHED_AT` and the extra row fields, page size 100. |
| `ScopeAccessFailure` and `GhFailure` | Failure classification for states 4, 5 and 6. Keep the fixed, name-free messages. |
| `ScopeRowProblem` | Inline messages in Add by Name and on rejected entries after Apply. |
| `ScopeAccessSimulation.DiscoveryMode` (`complete`, `capped`, `partial`, `denied`, `identityMismatch`) | Drives the offscreen renders and QA for each state. Add `rateLimited`, `signedOut` and `empty` modes. |
| `SnapshotRenderer` | Add sheet renders, light and dark, one per state, to `render-check.sh` so QA and design sign-off use the real views. |

## Open questions for PM / Chris

1. **The 10-entry cap.** Decided (Chris, 2026-11-22): no product cap. The engine keeps a technical
   ceiling of 500 for GitHub's per-request limits (#140); the UI shows a scrolling list with a
   more-entries cue instead of a counter.
2. **Apply in the sheet**: decided (Chris, 2026-11-22). Apply in the sheet saves and starts
   monitoring; there is no second Apply in Settings.

## Reproducing the images

```sh
swiftc -O docs/design/scope-browser/mockups.swift -o "$TMPDIR/scope-mockups"
"$TMPDIR/scope-mockups" docs/design/scope-browser
python3 -I scripts/png-optimize.py docs/design/scope-browser/*.png
```

The script creates offscreen borderless windows only. It never launches the app bundle, never calls
gh and writes nothing outside the output folder. `~/Library/Preferences` was listed before and after
the run, with no difference. The current-state images in `current/` come from
`scripts/render-check.sh` (`settings-scope-long*.png`) on 5902689, built with
`scripts/build-app.sh`.
