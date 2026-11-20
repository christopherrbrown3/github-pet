import Foundation

// #87 Inbox slice: FeatureFlags mirrored verbatim from PR #97 (feat/87-settings-panes), which owns
// this file. On merge, keep #97's version of the whole file.

/// One switch per feature a later issue may hide from the UI (#94 privacy mode / Show details,
/// #95 snooze). Every user-facing entry point for the feature checks its switch, so hiding it is a
/// one-line flip here plus "effective value off while hidden" logic. Both are on: behavior is
/// unchanged.
public enum FeatureFlags {
    public static let privacyMode = true
    public static let snooze = true
}
