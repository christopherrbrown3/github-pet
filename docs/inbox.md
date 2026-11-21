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

## Dismiss or restore an item

1. Select the **×** next to a review request, assigned issue, authored pull request, or entitlement
   review to dismiss it from your Inbox.
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
