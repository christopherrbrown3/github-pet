PR50 functional QA checkpoint — INCOMPLETE / HOLD

Exact head: 33f36f12a3f51b87d58df2c907a5cb8690d4ca63.
Current-head CI43775715168 SUCCESS, independently read through gh. Functional app is the preserved local release/arm64/ad-hoc bundle in qa-verify-33f36f1, not the CI artifact. Git HEAD and Info.plist source revision both match; binary SHA256 b679ae386950cca40b14ff08ded98ca045f79ff13ef3ce341712dcb9f173f011. Existing build.log records BUILD_EXIT=0; no build/test rerun by Codex QA.

Inspected existing t52 before any app operation. The preserved hostile-pack helper remains active; no duplicate app launch, signal, source change or preference cleanup performed. User saved app pid31897 was observed at its original saved b0127f0 path and left untouched.

Completed stderr captures reviewed: normal, how-to, newline, ansi, rtl, zero-width, long-ascii, long-emoji, combining, scalar-cap-300. Each has exactly one mascot-pack launch line and 208 PNGs present. No Cc/Cf/Zl/Zp/Co/Cn/Cs characters in the emitted label. Normal id remains qa-normal-pack; zero-width case becomes abcdefg; bidi marks disappear; newline/ANSI controls cannot create a second log line. ASCII/emoji truncate at 48 visible characters plus ellipsis. Combining and scalar-cap-300 stop at 256 scalars plus ellipsis, without the later pack-B text. Raw original stderr is retained; partial-inspection.json records label scalars and hashes.

Viewed and copied into inspected-pngs/: normal/settings.png (light), how-to/settings-dark.png, long-emoji/01-baseline-hover.png. Settings renders readable controls and Fixtures (offline), with no rejected-pack error for successfully loaded packs. Hover renders Demo incident and three-item fixture summary. These valid-pack images do not establish sanitized rejection text. Existing stderr includes two hover-placement warnings per completed render; no attribution to PR50 or full hover-layout acceptance is made.

Pending: scalar-cap-256/257, combining-many, empty-after, empty, hostile-dir, error-path, error-missing. Final helper exit, per-case exit/isolation checks, complete real-preferences comparison and saved-process before/after summary are unavailable until helper completion. The helper writes its consolidated JSON/Markdown only after all 18 cases. Settings rejection visuals and fallback labels are not yet verified. No overall product PASS or defect-free claim.

Limits: offscreen actual app views only; no pointer/AX, live motion, VoiceOver, physical Intel, clean-Mac install or live GitHub evidence. No unit/core-linked harness authored or executed. Existing untracked docs and runner are preserved.

Next: collect the existing helper completion without duplicating it, inspect rejection/fallback evidence, then report final PR50 verdict. PR49 remains held at known 0f0c65c59b379b9bd31860b689fb79ddb7937f6c until developer delivers the hardlink fix at a new exact head with green CI and immutable artifact. Old scope driver was read only: JSON filepath, runner.json exclusion, per-step -inbox/-mascot PNGs and safe normal-quit behavior need adaptation before use. No PR49/51/53 app run begun.
