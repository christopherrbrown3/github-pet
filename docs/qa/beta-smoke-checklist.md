# GitHub Pet beta RC: live smoke checklist (run with Chris)

This is a step-by-step script for **Chris** to run on the beta RC build, on his own Mac and his real GitHub CLI account, with QA following along live.

QA ran **no app** to write this. It is based on source and QA evidence at main `dcb0fc2` plus PR64, PR65 and PR68. The RC build may change wording slightly; anything that differs is worth noting.

**Coverage tags:**

- **LIVE-ONLY:** nothing automated or simulated covers this. This session is the only check.
- **LIVE-CONFIRM:** unit, simulated or offscreen tests cover the logic; this session confirms it against real GitHub, macOS and timing.

**Ground rules:**

- Chris launches, clicks and quits the app himself. QA does not drive the GUI.
- Nobody deletes preference files during the run. Uninstall step 14 is Chris's own optional step, at the end.
- Capture a **screenshot**, or a short note with the time, for each item marked *Capture*.
- Redact private repo or org names before sharing, or turn **Privacy mode** on.

**Before you start:** note the RC's commit SHA and CI run, and the macOS version and chip. Check that the old saved build `b0127f0` is still running (PID 31897), or decide to quit it first. Two copies show two menu-bar icons and two mascots.

---

## 1. Install and Gatekeeper (LIVE-ONLY)

1. Download the `GitHubPet-app` artifact from the RC's push run on `main` (or the run PM names). Then run `shasum -a 256 -c GitHubPet-*-universal.zip.sha256`.
   - **Expected:** `OK`.
2. Unzip it, move **GitHubPet.app** to **Applications**, and open it.
   - **Expected:** macOS says it can't verify the app. Choose **Done**, not Move to Bin/Trash.
3. Go to **System Settings → Privacy & Security → Security**, click **Open Anyway** and authenticate. Then open the app again and choose **Open**.
   - **Expected:** the app launches. There is a menu-bar icon, no Dock icon, and the mascot appears near the bottom-right.
   - **Never:** remove quarantine attributes or turn Gatekeeper off.
- **Capture:** the macOS version, the exact prompts you saw, and any step that differed from `docs/install.md`.

## 2. gh detection (LIVE-ONLY)

1. Open **Settings** (gear in the Inbox) → **Data source** and pick **GitHub CLI (gh)**.
   - **Expected, signed in:** the status line leaves Loading, and the Inbox shows the account's monitoring scope header.
   - **Expected, gh missing:** "GitHub CLI not found. Install it with: brew install gh".
   - **Expected, signed out:** a sign-in hint (`gh auth login`), never an empty inbox.
2. Optional, if Chris is willing: in a separate Terminal, `gh auth status` should match what the app reports. Do **not** run `gh auth logout` on the real account just to test this.
- **Capture:** the status line and the Settings account row (the login can be redacted).

## 3. First sync is a silent baseline (LIVE-CONFIRM)

Simulated QA shows the silent baseline; real data is LIVE-ONLY.

1. Right after switching to gh, wait for the first successful poll.
   - **Expected:** existing review requests and assigned issues appear **without** "new" dots, an attention animation or an unseen count. The badge shows the count, with no `+` unless it's Partial.
- **Capture:** the Inbox and mascot right after the first sync.

## 4. Real items appear and open GitHub (LIVE-ONLY)

1. Compare the Inbox with github.com: review requests (`is:pr is:open review-requested:@me`) and assigned issues (`is:issue is:open assignee:@me`).
   - **Expected:** the same items are listed. Up to 30 per category, then Partial "N+".
2. Click a row.
   - **Expected:** the default browser opens **that** pull request or issue on github.com. Nothing is changed on GitHub.
3. Turn Privacy mode on (the default): titles and repository names are hidden until **Show details**.
- **Capture:** counts in the app vs. on github.com, and one opened URL.

## 5. Monitoring scope: Apply and Cancel (LIVE-CONFIRM)

Simulated flows are covered (accf14b, e57d1f3, 3f89207); the real account is LIVE-ONLY.

1. Go to **Settings → Monitoring scope**, choose **Selected organizations and repositories**, and add one org or repo you can read. Optionally use **Find suggestions**.
2. Click **Cancel**.
   - **Expected:** the draft is discarded and the active scope is unchanged.
3. Add the entry again and click **Apply**.
   - **Expected:** "Checking access…", then applied. The Inbox header reads "Monitoring scope · Selected · …", and only matching rows remain. Public GitHub incidents are still shown.
4. Add an org or repo you **can't** read, then Apply.
   - **Expected:** a per-row error, "Nothing was applied", and the active scope unchanged.
5. Switch back to **Everything accessible** and Apply.
- **Capture:** Settings after each step, and the Inbox header.

## 6. Entitlement repositories (LIVE-ONLY)

PR65 adds this. The unit tests cover classification only; no app run has shown it.

1. Go to **Settings → Entitlement approvals** at the bottom and add a repo (`owner/name`) that currently has a review request for you.
   - **Expected:** it is listed with a key icon. Invalid input, a duplicate or a 21st entry each show a fixed message.
2. In the Inbox, the matching review request now shows as an entitlement (key icon, "Entitlement update" label).
   - **Expected:** **no** new dot or animation, because nothing re-announces.
3. Click it.
   - **Expected:** the **same pull request** opens on github.com. Nothing is approved in the app.
4. Remove the repo.
   - **Expected:** the row goes back to "Review request", again with no animation.
- **Capture:** the row before and after, and the opened URL.

## 7. Partial and error never look empty (LIVE-CONFIRM)

Simulated and unit tests cover this. Real SAML or 403 responses are LIVE-ONLY.

1. Watch the status line during this session.
   - **Expected:** a failed or partial source shows "Partial data", an error or a hint, with last-known rows dimmed. It **never** shows "All clear" or an empty list while data is unknown.
2. If Chris has an org that enforces SAML SSO and isn't authorized for gh, put it in a **Selected** scope with one readable target, and Apply.
   - **Expected:** Partial, with the readable rows and "GitHub denied access to part of this scope (token scope or SAML single sign-on)… Run gh auth refresh." No org names appear in the message.
3. Optional: disable Wi-Fi briefly.
   - **Expected:** an error or stale state with rows kept, never empty. Then turn Wi-Fi back on.
- **Capture:** any partial or error state you see.

## 8. Refresh while polling (LIVE-CONFIRM)

Unit tests cover the queue; there is no app-level coverage.

1. Click **Refresh** and immediately click it again while the label reads **"Refreshing…"**.
   - **Expected:** the label says "Refreshing…" only while the poll runs. The second click runs one more refresh after the first finishes. It isn't lost, and the clicks don't pile up.
2. Optional, wake: sleep the Mac for at least a minute and wake it.
   - **Expected:** one refresh about 5 seconds after wake, gh source only. **LIVE-ONLY.**
- **Capture:** a screenshot showing "Refreshing…".

## 9. Quit, relaunch and new items (LIVE-ONLY across a real relaunch)

Unit tests cover this at app level; there is no real two-launch run.

1. Note the current items. Quit with the Inbox **power** button, then relaunch from Applications.
   - **Expected:** the Inbox shows Loading until the first poll, then the same items with **no** new dots or animation.
2. While the app is quit, have a teammate request your review on a PR, or assign you an issue. Then relaunch within 24 hours.
   - **Expected:** that one item shows as new and animates **once**. A Refresh doesn't replay it.
3. Optional: relaunch more than 24 hours later.
   - **Expected:** a silent re-baseline.
- **Capture:** the time of quit and relaunch, and the Inbox after relaunch.

## 10. Open at login (LIVE-ONLY)

PR62. **Chris flips it himself; QA never does.**

1. Go to **Settings → Startup**.
   - **Expected:** "Checking with macOS…", then the real state: "Off." / "On…" / "Pending approval…" / "Unavailable…".
2. Turn **Open at login** on.
   - **Expected:** "On: GitHub Pet opens when you log in." **or** "Pending approval. Allow GitHub Pet in System Settings → General → Login Items." If it's pending, approve it in System Settings and come back. The text should update when the app becomes active again.
   - A failure shows "macOS didn't turn on open at login. Status now: …", never raw system text.
3. Optional: log out and back in.
   - **Expected:** the app opens.
4. Turn it **off** again, unless Chris wants to keep it. Check that **System Settings → Login Items** agrees.
- **Capture:** each status line, the Login Items entry, and whether this ad-hoc-signed build registers at all.

## 11. Mascot, privacy and quiet hours (LIVE-CONFIRM)

1. **Settings → Mascot → Show mascot** off, then on.
   - **Expected:** the mascot hides and returns, and the menu-bar icon still works. Then drag the mascot and use **Reset position**.
2. **Privacy mode** on.
   - **Expected:** no titles or repository names in the Inbox, hover or menu bar until **Show details**. Turning it on again re-hides them.
3. **Quiet hours** on with the current time inside the window, or **Snooze → 1 hour**.
   - **Expected:** the Inbox keeps updating, but the mascot and menu-bar icon stay calm, with no animation for new items. No backlog plays when it ends.
4. **Reduce motion** on.
   - **Expected:** the mascot stays still.
- **Capture:** any state that looks wrong.

## 12. Hover and popover dismissal (LIVE-ONLY)

#41. Covered only by the Developer's controller tests.

1. Hover the mascot until the summary shows.
2. Close it with **Esc**, with a **click on the empty desktop**, or (optionally) by switching **Space**. Wait for a refresh or the next item.
   - **Expected:** the summary does **not** reappear on its own. Hovering again shows it.
- **Capture:** anything that re-opens unexpectedly.

## 13. Accessibility spot check (LIVE-ONLY)

1. With VoiceOver on, focus the mascot.
   - **Expected:** it reads as one button and pressing it opens the Inbox.
2. Reach the menu-bar icon using "Move focus to status menus", if that shortcut is enabled.
- **Capture:** what VoiceOver says.

## 14. Uninstall (LIVE-ONLY, optional, Chris's choice)

1. Turn off **Open at login** first (Settings → Startup), or remove the app under Login Items.
2. Quit using the power button, then move **GitHubPet.app** to the Bin/Trash.
3. Optional, Chris only: run `defaults delete dev.github-pet.GitHubPet` to remove settings. QA never runs this. Older `dev.github-pet.*` QA/dev plists are a separate decision for Chris.
   - **Expected:** nothing of GitHub Pet is left in Login Items, and gh and its sign-in are untouched.
- **Capture:** the Login Items list afterwards.

## 15. Your own pull requests (#9, LIVE-CONFIRM)

The simulated QA run covered this (PR71 711571e). The real GitHub states, and especially changes requested and merge conflicts, are LIVE-ONLY.

1. With the GitHub CLI source, have one of your open PRs in each state, if possible:
   - a reviewer requested changes
   - a merge conflict with its base branch
   - a failing check on its latest commit
   - one that is approved, a draft, or still waiting for review
   - **Expected:** each PR that needs your action is **one** row, "Your pull request · <reasons>" (for example "Changes requested, Checks failing"). It announces once and opens the PR on github.com. Approved, draft and still-checking PRs are **not** rows. They appear only in the hourglass line "N of your pull requests are waiting on others or being checked by GitHub", which never changes the badge or mood.
2. Mark everything seen (open and close the Inbox). Then **improve** one PR: fix its failing check, or resolve its conflict, while keeping changes requested.
   - **Expected:** the row's reason text updates with **no** new dot and **no** animation.
3. Push a **new** commit that fails checks.
   - **Expected:** one new alert for that PR (new failing commit).
   - Re-running the failing workflow on the same commit doesn't alert again.
4. With Privacy mode on, the row shows "Your pull request · <reasons>" without the title or repository.
- **Capture:** the rows and the waiting line before and after each step, and the times.

## 16. GitHub Actions: workflow failures and deployment approvals, opt-in (#10 slices 1–2, LIVE-ONLY)

This needs builds with PR72/PR73 (workflow failures, independent of the inbox) and PR75 (deployment approvals). It has **no simulated coverage**, and the renderer doesn't show this Settings section.

1. In **Settings → Monitoring scope**, pick **Selected** with at least one repository whose default branch already has a failing GitHub Actions run, and Apply.
2. Check **Settings → GitHub Actions**.
   - **Expected:** both toggles, "Watch workflow failures…" and "Watch deployment approvals…", are **off** by default, and the Inbox has no workflow or deployment rows.
3. Turn **Watch workflow failures** on.
   - **Expected:** the note says "Watching N repositories." (plus a note if organizations are also selected).
   - The existing failures appear as rows, "Workflow failure · <workflow> failed on <branch>", **without** a burst: no new dots and no attention animation for failures that were already there.
   - If one of them is a run **you** triggered, the mascot shows the **urgent** state while it exists. Other people's failures are rows only.
4. With it on, push a commit to the default branch whose workflow fails. If it's your own commit, it counts as yours.
   - **Expected:** **one** alert for the new failure, and urgent if you triggered it.
   - Re-running that workflow and having it fail again doesn't alert again. A fixed run removes the row on the next refresh.
5. Optional: a selected repository you can't read, or a SAML-protected one.
   - **Expected:** a separate line, "GitHub Actions: … showing last known", with earlier failure rows kept and marked "· last known". Never "no failures".
   - The **inbox itself stays complete**: a new review request still alerts. If the inbox is otherwise empty, it shows Partial, never All clear.
6. With Organizations or Everything selected and no repositories:
   - **Expected:** the note says "GitHub Actions: select repositories in Monitoring scope to watch them…", and no Actions query runs.
7. Turn **Watch workflow failures** off.
   - **Expected:** the workflow rows disappear on the next refresh, and nothing else changes.
8. **Deployment approvals (slice 2).** Use a selected repository with an environment that requires reviewers.
   1. Start a workflow run that waits for that environment, and make sure **you** are an allowed reviewer.
   2. Turn **Watch deployment approvals** on.
      - **Expected:** if a run was already waiting, it appears **without** a burst. Turning on this second part re-seeds the GitHub Actions rows silently.
   3. Start a **new** waiting run.
      - **Expected:** **one** alert. The row is "Deployment approval · <workflow> is waiting for your approval to <environment>", with a shield icon.
      - Clicking it opens the **run page** on github.com. **Approve or reject there, in the browser, not in GitHub Pet.**
      - GitHub Pet has **no** approve action. Confirm that nothing in the app approves, and that the run is still waiting until you act on GitHub.
   4. A waiting run where you are **not** an allowed reviewer (another environment or another reviewer).
      - **Expected:** **no** row. It only appears in the hourglass line "N deployment(s) waiting for other reviewers or a wait timer", which doesn't change the badge or mood.
   5. After you approve on GitHub, the row disappears on the next refresh with no further alert. Turning the toggle off clears the rows and the waiting line.
- **Capture:** Settings notes, rows, mood, badge and the waiting lines before and after each step. Note whether turning anything on caused an animation (it shouldn't), and confirm by GitHub's own UI that the run was never approved by the app.

---

## Results to report back

For each section: **PASS / FAIL / NOT RUN**, with the captures, the RC SHA, the macOS version and the time. Give any FAIL to QA with steps to reproduce; QA turns it into a Developer issue. Live-only items with no other coverage are sections 1, 2, 4, 6, 9, 10, 12, 13, 14 and 16, plus the real-account parts of 3, 5, 7, 8, 11 and 15. Sections 15 and 16 need builds that include PR71 and PR72/PR73 (and PR75 for §16 step 8); skip them on the v0.1.0-beta.1 build.
