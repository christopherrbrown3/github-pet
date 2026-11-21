# Accessibility checklist (#13, #15, #104)

`Tests/GitHubPetAppTests/AccessibilityTreeTests.swift` hosts the real Inbox, Settings (Mascot and
GitHub panes) and desktop-mascot views in offscreen windows. It reads the same NSAccessibility tree
VoiceOver reads, in light and dark mode. No mouse or keyboard events are sent and no assistive
tool is launched. SwiftUI only publishes its tree while an assistive client asks for it, so the
test sets `AXEnhancedUserInterface` on the app in-process, as assistive apps do, and clears it
afterwards. Nothing is written to disk.

## What the tests prove

- **No unnamed controls or images.** Every button, link, switch, radio button, pop-up, menu
  button, slider, text field and disclosure triangle has a real spoken name (not an SF Symbol name
  such as `arrow.clockwise`). Every exposed image has a label. This holds in each Inbox state:
  loaded, empty, stale, partial, error, signed out, gh missing, loading and the dismissed list. It
  also holds in the Settings Mascot and GitHub panes, including signed out, selected scope and a
  login item that needs System Settings.
- **Disabled controls say why** in their hint: Open at login, locked skin cards, Check for
  Updates, automatic install, beta releases, scope Apply and Cancel, the suggestion menus and
  entitlement Add.
- **Inbox rows** are one button each. The name holds the title, kind and repository (with "New."
  when unseen), and the hint is "Opens on GitHub". **Open on GitHub** and **Dismiss Here** are
  named actions in the VoiceOver Actions rotor, and a separate "Dismiss <title>" button remains.
  Running the Dismiss action through accessibility shows a named "Undo dismiss <title>" button, and
  pressing it brings the row back.
- **The count badge and mascot announce count and state.** The Inbox header mascot is one image
  whose label is the menu-bar status, e.g. "GitHub Pet, Demo data, 4 items, needs attention". The
  label always includes the badge's number and words for stale, partial, error, loading, signed out
  and gh missing. The desktop pet is one button with the same status and its summary, the hint
  "Opens the inbox", no unlabelled child elements, and a press that opens the Inbox.
- **Headings.** "Needs you" and each section ("Review requests, 2") are headings.
- **Keyboard, as far as offscreen allows.** Every text field in Settings › GitHub is in the
  window's key-view loop. Every SwiftUI button supports the accessibility press action. Refresh
  keeps ⌘R.

## Gaps found and fixed

| Gap | Fix |
|---|---|
| **Undo after Dismiss did nothing.** It hid the banner but never restored the row: Undo passed the raw item id, but dismissals are keyed by digest. This affected everyone, not only VoiceOver. | Undo uses the digest, as Restore does. |
| Inbox header mascot read only "4 items", with an unknown role and no state. | Image with the full status label. |
| Overview tiles had an unknown role. | Static text. |
| Rows had no named actions. | Open on GitHub and Dismiss Here as actions. |
| Open at login: the summary was set as the switch's value, which VoiceOver never reads (a switch's value is on/off). The disabled switch gave no reason. | The summary is now the hint. |
| Size slider was read "Mascot size, Mascot size". | Labelled once. |
| Scope inputs were read "Add organization, New organization, login". | Labelled once. |
| Entitlement field was named only by its placeholder. | Named "New entitlement repository, owner/name". |
| Disabled skin cards, Check for Updates (×2), automatic install, beta releases, scope Apply and Cancel, suggestion menus and entitlement Add gave no reason. | Hints say why. |

The UI is visually unchanged. Settings and scope renders are pixel-identical to main. The other
render differences are the clock and mascot animation, which also differ between two runs of the
same build.

## What can't be proven offscreen

- Actual speech: verbosity, order, and whether VoiceOver reads a hint or row value aloud.
- Tab order and focus rings for SwiftUI buttons. These depend on System Settings › Keyboard ›
  Keyboard navigation, which tests must not change.
- The menu-bar popover: its first responder, Escape to close, and moving VoiceOver into it from
  the menu bar.
- Live announcements when the count or state changes. None is posted today (only the scope
  editor announces its status), so the change is heard only when the user moves to the mascot
  or badge.
- Whether the desktop pet, a floating non-activating panel, can be found with VO-F5/the window
  rotor.
- Large text (Dynamic Type) and Increase Contrast, covered only by InboxRowMetrics and contrast
  unit tests.

## 10-minute VoiceOver pass (by hand)

Use a QA or fixtures build (`--fixtures`, Demo data), not your real account. Turn VoiceOver on
with ⌘F5.

1. **Menu bar (1 min).** Move to the GitHub Pet icon (VO-M twice, then arrows). Expect "GitHub
   Pet, Demo data, N items…". Open it with VO-Space.
2. **Popover focus (1 min).** Expect VoiceOver to land inside the Inbox. Press Escape: the popover
   should close and focus should return to the menu bar.
3. **Inbox header (1 min).** Expect the mascot image to read "GitHub Pet, Demo data, N items…",
   then GitHub Pet, the status, Refresh, Settings and the three overview tiles with values. Check
   that ⌘R refreshes.
4. **Rows (2 min).** Move to a row. Expect title, kind and repository, then "Opens on GitHub". Open
   the Actions rotor (VO-⌘-Space): Open on GitHub and Dismiss Here. Choose Dismiss Here, then find
   and press "Undo dismiss …". The row must come back.
5. **Keyboard only (1 min).** Turn on Keyboard navigation. In the Inbox window, Tab should reach
   Refresh, Settings, rows, Dismiss and the footer buttons with a visible focus ring.
6. **States (1 min).** Use the Simulator menu: Mark data stale, then Simulate disconnect. The
   mascot and status should say "stale" and "Error".
7. **Settings › Mascot (1 min).** Expect "Show desktop pet, switch", the skin cards with
   Selected/Not selected (and the reason when locked), "Mascot size, slider" read once, and Open at
   login with its status as the hint.
8. **Settings › GitHub (1 min).** Expect Recheck, the Source pop-up, scope radio buttons,
   Cancel/Apply with a reason when dimmed, and the entitlement field named "New entitlement
   repository".
9. **Desktop pet (1 min).** Find the pet (VO-F5 / window rotor). Expect one button with the status
   and "Opens the inbox". VO-Space should open the Inbox.

Report anything that reads differently from the expectations above on #13.
