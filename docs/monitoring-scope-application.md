# Monitoring scope: application slice A

This slice connects the accepted scope client to the application. The ordinary Settings scope editor, discovery and live draft validation follow in PR B; this is not the complete #30 feature.

A repository scope session restores the last-known github.com viewer's stored selection before its first fetch. That request includes the expected viewer node ID. If identity is unknown, an unrestricted response first resolves the returned viewer's record: a saved Selected scope discards those bootstrap rows and refetches. A different viewer also discards the submitted scope's reply and restores that viewer's own selection. One cycle permits at most one follow-up, with the **same 20-second monotonic budget and aggregate 2 MiB output allowance**, plus the transport's existing bounded cleanup. Further identity churn or budget exhaustion is an explicit failure, never a fallback to Everything.

The MainActor session uses generation plus request serial guards. Apply persists only for the expected identity/generation, cancels the old task, clears repository rows/unseen/baseline/attention, and starts a silent baseline. Future Settings code must validate access before invoking this commit seam. Scope/account resets never call the full data-source switch or reset public incidents. Clips retain repository/service origin and their original time bounds (at most one per origin); removing repository attention preserves concurrent service attention without restarting it. A genuine data-source switch still resets both sources.

Unknown, invalid identity, corrupt selection and failed bootstrap stay errors/loading; they cannot become a verified empty inbox. Scoped partial/error/cap details reach a generic quality message. Proven partial rows use the existing engine's silent recovery rules. Inbox scope summaries use mode and target counts, without target names, including when privacy is off. Demo uses its own selection record. The new last-viewer record contains only supported host and opaque viewer node ID, not a token or login.

## Offline functional QA in the actual app

Run the exact-head CI app binary with the explicit flag:

```sh
/path/to/GitHubPet.app/Contents/MacOS/GitHubPet --simulate-monitoring-scope
```

The flag is **off by default**. It forces a fresh randomly named `dev.github-pet.scope-simulation.*` defaults domain, seeds only invented accounts/targets, uses no gh process or network (including public status), and labels the app Demo and Simulated. Caller defaults-suite overrides cannot select a real account store. Quitting normally removes this simulation domain. Periodic repository polling is disabled; use Refresh and the **Simulated scope** menu in the Inbox. The normal data-source picker can exercise source changes; return to GitHub CLI within this simulated launch for account scenarios. Even there both sources remain offline. Normal launches have no simulated controls, seeded accounts or fixture transport.

The menu reports account, request count, held replies, last requested scope/expected account, and discarded late replies. Turn privacy off in ordinary Settings to inspect invented rows; the scope summary itself remains generic. Keep one QA app running at a time and preserve the user's installed app/settings. These steps are for functional observation, not a request for QA to author unit harnesses.

- **Restore before display:** initial launch is saved A Selected (`demo-a`), one row, no unseen/gesture. The last request is Selected/expected A. “Reload saved A (unknown viewer)” first requests Everything, discards its outside row, then requests bound Selected; `demo-outside/pet` must never appear as active rows during that restoration. “Reload saved A (known viewer)” requests Selected directly.
- **A→B→A:** choose Account B, then A. B restores its saved explicit `demo-b/pet` repository; A restores its organization. Each settles with one row and no new alert. Accounts are simulated, not changes to `gh auth`.
- **Late reply after Apply:** hold the next repository reply; wait until the menu says one held. Apply Everything (simulated validation), then inject a new row. There should be three rows and one new unseen event. Deliver held replies: discarded count increases and the older one-row Selected result cannot replace the new rows/attention. Refresh unchanged must not announce again. Release within the bounded 20-second cycle.
- **Corrupt saved Selected:** corrupt saved A and reload. It shows configuration error with no verified-empty state or broadening. Repair saved selections restores the one-row Selected baseline silently.
- **Partial→recovery/new-once:** start with repaired selections. Set partial replies and inject a row: partial count, no new gesture. Complete replies/recover: silent baseline. Inject another row: one new unseen event/gesture, unchanged Refresh does not replay it.
- **Incidents preserved:** inject a major public incident in the Simulated scope menu, then Apply Everything or Selected. Its incident rows/unseen marker/burst and still-active service clip retain their original timing. Scope Apply does not refetch/reset public status. Existing motion/quiet/snooze controls can intentionally suppress gestures without changing source truth.
- **Privacy and source change:** scope header contains counts, not target/account names. Hold a repository reply, switch the data-source picker to Fixtures, deliver it: it is discarded and Demo keeps its separate scope. Return to GitHub CLI to restore the simulated account's selection. Real account selections are never written.

## Developer evidence

Developer owns the committed pure session/clip/budget tests and the new native AppModel test target. Tests cover saved/unknown bootstrap, A→B→A, reverse-order Apply/source replies, stale commit guards, corrupt configuration, partial recovery/new-once, incident state/unseen/burst/clip preservation, generic summaries, launch isolation, shared cycle byte exhaustion and no preflight after deadline. Manual GUI, pointer, VoiceOver, physical Intel and clean-Mac Gatekeeper validation are separate functional evidence; unit assertions and offscreen renders do not establish them.
