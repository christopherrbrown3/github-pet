# Using the Inbox

Open the Inbox from the menu-bar icon or the mascot. Select a row to open the item on GitHub.

## Choose which review requests appear

Open **Settings → GitHub → Review requests** and choose an **Assignment filter**:

- **Show all notifications** includes pull request reviews requested from you or your GitHub teams.
  This is the default.
- **Show only assigned to @me** includes reviews requested directly from you, even when a team
  was also asked to review.

Both choices include issues assigned to you and your own pull requests that need attention.
Configured entitlement reviews follow the same review filter. The filter works within your
[monitoring scope](monitoring-scope-settings.md). Service incidents and opt-in GitHub Actions
sources keep their own coverage.

Changing the filter refreshes the review list. Reviews already waiting in the new selection
appear quietly. Your unread assigned issues and authored pull requests keep their unread markers.

## See what's waiting on others

Your open pull requests that need nothing from you right now, and deployments waiting for someone
else's approval or a wait timer, are listed in a **Waiting on others** group below the groups that
need you, as a section of its own. It starts collapsed with its count. Select its header, or the
**Waiting on others** tile, to expand it. Each row says why it waits where GitHub reports it:
**Draft**, **Review pending**, **Checks running**, **Checking for conflicts**, **Approved, ready to
merge**, or, for a deployment (titled with its workflow name), **Approval or wait timer**. A row shows
the first reason; its tooltip and VoiceOver give every reason, and for a deployment the full
wording, "Waiting for deployment approval by others or a wait timer".

An approved pull request with nothing else pending stays here: GitHub Pet doesn't alert you to merge
it.

These rows never count in the badge and never alert or notify. When a pull request starts needing
you (for example, changes are requested), it moves to **Your pull requests** and alerts as usual.
When results are partial the count reads "at least", and when they are stale or failed it reads `?`
and the rows are marked last known.

With VoiceOver, the group header reads its name, count and whether it is expanded or collapsed.

## Dismiss or restore an item

1. Select the **×** next to a review request, assigned issue, authored pull request (including one
   under **Waiting on others**), or entitlement review to dismiss it from your Inbox. Dismissing a pull
   request under **Waiting on others** hides it only while it waits: if it later needs you (for
   example, changes are requested), it appears under **Your pull requests**, counts in the badge and
   alerts as usual.
2. Open **View dismissed** to see saved dismissals for the active account.
3. Select **Restore**, then **Back to Inbox**. A restored item that still matches your current
   view returns without an alert. If it is unavailable in this view, restoring it allows it to
   appear if GitHub returns it later.

Dismissals stay on this Mac across normal app restarts. GitHub accounts and Demo data keep
separate lists. Dismissing an item changes only
your local Inbox. GitHub still has the original item and assignment.

The list holds up to 512 dismissals per account or Demo. Restore an entry to make room if it is full.
Workflow failures, deployment approvals, and service incidents are outside this list. Loading,
partial results, and connection errors still show their own status even when every visible item
is dismissed.
