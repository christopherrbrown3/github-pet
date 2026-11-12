# Native macOS UI specification

Mode: Operate. A quiet desktop companion gives one glanceable summary and one shared inbox. The generated mascot is companion content. Use a neutral inbox symbol for the app's menu-bar identity, rather than an official GitHub or Octocat logo. All examples in the review board are invented public-safe fixtures.

## Inbox and menu bar

Use the system menu-bar extra with standard controls in a popover-like window, as described by Apple's [MenuBarExtra documentation](https://developer.apple.com/documentation/swiftui/menubarextra). Aim for 360 points wide, 16-point outer spacing, SF system type at 13 points, 15-point semibold title, 11-point secondary metadata, and standard keyboard focus. Use system `label`, `secondaryLabel`, `windowBackground`, separator and selection colors. Let system materials, increased contrast and reduced transparency choose their native appearance. The HTML board approximates these semantic colors for review; its CSS is not a native implementation recipe.

The authored template SVGs under the pack's `ui/` directory specify 22×18-point neutral, attention, urgent, unknown and paused symbols. Render monochrome template artwork with system tint; export at display scale. Never animate the menu-bar icon. Use text count only when known; `2+` means a verified lower bound, not an exact total. Unknown is `?`, never `0`. Failure is an exclamation cue plus explicit words in the inbox, not color alone. Do not use badge color to encode repository identity.

Menu-bar button and mascot click open the same inbox, preserving selection and scroll position. Return focus to the invoking control on dismissal. Escape dismisses; Tab/Shift-Tab traverse controls; arrow keys navigate the list; Return opens the selected item's HTTPS GitHub page. Command-comma opens Settings; Quit is available in the menu. Give the menu-bar control a useful accessible label, for example “GitHub Pet, at least 2 items, some sources unavailable.” The mascot is one button, not separate accessible limbs. No hover-only actions.

Order: title and known summary → quality notice if needed → urgent items → actionable items → waiting-on-others section → freshness → Refresh, Settings and Quit. Rows show category, short title, optional repository metadata, quality and a named “Open on GitHub” action. Long titles wrap to two lines then truncate with the complete accessible label; full details belong on GitHub. Lists scroll beyond roughly 440 points high. Pinning the popover or moving its anchor must not duplicate the inbox state.

## Hover preview and speech bubble

Hover after 500 ms shows a nonactivating 220-point-wide preview: “2 items need attention” and “Some sources unavailable.” Hide after leaving both mascot and preview for 200 ms. Preview is supplementary; focus, click and the menu-bar inbox expose the same information. Hover never plays an event or opens a browser.

A verified new event may show one 260–300-point speech bubble. Use a native rounded popover surface, 12-point inset, maximum three text lines, a category symbol and clear title, one “Open inbox” action and a labeled dismiss button. Tail points to the mascot's reserved canvas, outside its face. Prefer the side with room, constrain the entire bubble to `visibleFrame`, and detach the tail if necessary. The bubble is not a modal and must not steal focus or obscure the menu bar. Keep text stationary; no typing effect. Auto-dismiss after 8 seconds, pause dismissal while hovered/focused, and retain the item in the inbox. System/app Reduce Motion shows a static bubble immediately. Respect quiet hours and snooze; don't replay deferred events when either ends.

## Data quality is separate from mood

| Source quality | Copy and count | Companion behavior |
|---|---|---|
| unknown | “Not checked yet”, count `—` | neutral idle static/ambient; no all-clear claim |
| loading | “Checking…”; preserve clearly labeled last known value | neutral; no event clip |
| fresh empty | `0` for that source | “All caught up” only when every enabled source is fresh, known and zero |
| fresh nonempty | known count and actionable/waiting distinction | attention only for verified actionable items |
| partial | “Some results unavailable”; known lower bound such as `2+` | retain known items; no inferred zero or all clear |
| stale | “Last checked 12 minutes ago”; value labeled last known | no new event from stale recovery alone |
| error | “Couldn’t check Actions”; Retry | distinguish fetch failure from a confirmed GitHub incident |
| disabled | “Not monitored” | excluded from totals; never silently treated as zero |

Source-specific quality remains visible even if another source has a verified urgent event. “Waiting on others” does not imply user-can-approve. A failed workflow or confirmed incident may be urgent. Missing CLI/auth can use the concerned static pose with precise recovery text; these are connection problems, not confirmed incidents.

Reference semantics were read using committed `git show`, without touching hardware working files: `src/app_state.c`, `src/github_api.c`, `src/animation.c`, `design/docs/animations.md` at `28e05d8af821abdb6aedf59eff88e18ca95719e1`. Reused: known-count/quality separation, partial-result honesty, baseline suppression, stable event IDs, bounded monotonic motion and reduced-motion fallbacks. Hardware-specific timing/memory and authentication are not ported. Authenticated access in this app belongs to Developer's `gh` transport only.

First sync seeds stable event IDs and revisions without animation. Unchanged IDs/revisions never replay. Unknown, stale or error recovery without comparable prior data reseeds rather than manufacturing a new event. Account/scope changes establish a new baseline. Opening an old inbox item does not mark it as a newly observed event.

## Privacy, connection and settings

Privacy defaults to generic desktop and menu-bar summaries. Hide titles, repository/account/organization names and URLs in unsolicited bubbles, hover, tooltips, accessibility labels and logs. The inbox initially shows generic categories and an explicit “Show details” control for that session; turning privacy on immediately redacts an already open surface. Do not hide quality/freshness or urgency. Privacy and Reduce Motion are independent. Fixture simulations must say “Demo” so invented items cannot be confused with live GitHub data.

Connection states name the problem: “GitHub CLI not found” with installation guidance; “GitHub CLI is signed out” with local `gh auth login` instructions; “Access unavailable” for inaccessible scope; “Rate limited” with a known retry time if supplied. Do not display, request, store or log tokens. Do not add OAuth/App credential UI.

Settings use native controls for Show mascot, size (64–256 points; default 128), position/reset, privacy, Reduce Motion, snooze and quiet hours. Hiding the mascot leaves the menu-bar inbox available. Drag only from the mascot region, clamp its full canvas to display work area, and provide keyboard-accessible Reset position. Display removal falls back to the main display without losing the inbox. Offer a neutral contrast background for the black mascot when needed, including Increase Contrast; preserve the original transparent asset. Quiet hours do not mute explicit user-opened inbox content.

## Native acceptance handoff

Check dark/light appearance, 1×/2× displays, the 64-point minimum, long/localized strings, right/left screen edges, display changes, Escape/focus restoration, VoiceOver names, Reduce Motion, Increase Contrast and Reduce Transparency. Verify no passive surface leaks hidden metadata. Follow Apple's [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [motion](https://developer.apple.com/design/human-interface-guidelines/motion) guidance. These native checks remain for integration QA; a browser comp cannot prove them.
