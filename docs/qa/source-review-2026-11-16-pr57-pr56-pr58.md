# QA review: PR57 94d3235, PR56 cce3df0, PR58 22c0264

QA: Claude Opus 5.5 (`claude-opus-5-5`), task I from PM t61, 2026-11-16. This was read-only; no app ran.

For each PR, QA ran `gh run view` and confirmed that CI completed SUCCESS on that exact head. For each, `git merge-tree --write-tree <pre-merge> b74078b` equals the tree of the PR's main-merge commit, so all three merges were clean automatic merges with nothing extra.

| PR | Head | CI | Main-merge commit |
|---|---|---|---|
| 57 | 94d3235ec5e2641508fa9123bebd7a5381f7fbca | 43888738075 | 7804cc7 |
| 56 | cce3df02f75d1ac1ac608f77ed0159e4c3521bb6 | 43889389967 | f267666 |
| 58 | 22c02643e3c3dfda0df45e209553618af0dc778b | 43889857911 | 586ff40 |

## PR57: login item service (#15). Source PASS; functional not applicable

- **The fix:** `LoginItem.setEnabled(true)` now calls `register()` only when `!current.isRegistered`, and `requiresApproval` counts as registered.
  - Enabling an item that is waiting for approval makes no system call. It returns `requiresApproval` with no failure, and the explanation points to Login Items.
  - Disabling unregisters both `enabled` and `requiresApproval`.
  - Errors are reported in `failure`, and the status is always read again from the backend.
- **Developer evidence** (`/Users/chris/github-pet-builds/pr57-94d3235-developer-evidence`, base HEAD 7804cc7):
  - Before the fix, `requiresApprovalIsPendingNotRegisteredAgainAndCanBeUnregistered` reports 5 issues: `register` was called, the status became `enabled`, and with a throwing backend the result was the failure "denied".
  - After the fix, `LoginItemTests` passes 9/9.
- **Functional: not applicable.** `LoginItem`/`SMAppService` is not referenced anywhere in `Sources/` outside `LoginItem.swift`. There is no UI, no status display and no simulation or offscreen mode to observe. Any real check would mean calling `SMAppService` or opening System Settings, which is prohibited, so QA did **source review only**. No login item was touched.
- **INFO:** `@unknown default → .notFound` shows "Move it to Applications" for any future unknown status. That fails safe (not registered), but the advice could mislead.
- **INFO:** behaviour of real `SMAppService` on an ad-hoc-signed build is still unverified. The Developer disclosed this; it needs the UI PR plus a consented manual check.

## PR56: token-access scanner (#7, test-only). Source PASS with findings

The change is in `Tests/GitHubPetCoreTests/TokenAccessSourceTests.swift`.

**Verified correct:**

- **Interpolation depth:** the bound fails closed. At depth 16 the lexer emits `.unscannable`, which produces the violation "unscannable interpolation nesting"; it is never skipped. Recursion is bounded, and the token propagates up through the nested arrays. The test uses 40 levels.
- **Escape decoding:** `\0 \\ \" \' \t \n \r \u{1–8 hex}` are decoded, and raw `\#…` is decoded with matching hashes. An invalid escape or an invalid scalar (`\u{110000}`, surrogates) sets `escaped`, which fails closed in the subcommand position.
- **Comments and literals:** line comments and nested block comments are dropped. Raw strings with any number of `#`, and multiline strings, are each one token. Raw strings interpolate only with their own delimiter.
- **Review examples:** every Copilot review example is a test with the expected violation.
- **Documented limits:** concatenation, variables, regex literals, all `#if` branches being scanned, and Sources-only scope.

QA checked the scanner's `violations(in:)` by compiling a verbatim copy in a scratch build. That probe is not committed and no repo tests were added. It found these false negatives, all within the stated claim "asks gh to print a token":

- **MED-1: `["auth", "status", "-t"]` passes.** `-t` is gh's short form of `--show-token`. The rule allows any `"auth", "status"` and only matches the long `show-token` substring, so the allowed preflight can print the token unnoticed.
  - Fix: require the exact allowed argument list (`GhClient.authStatusArguments`), or reject any later `-t`/`--show-token` element in the same array.
  - Current Sources do not do this.
- **LOW-2: other ways to read a token are not listed.** `["config", "get", "oauth_token"]` makes gh print the stored token. Calling `security find-generic-password` or `find-internet-password` reads the Keychain without `SecItemCopyMatching`. Reading gh's `hosts.yml` directly is also missed.
  - Suggestion: add `oauth_token`, `find-generic-password`, `find-internet-password` and `hosts.yml` to the forbidden substrings. None appears in Sources today.
- **LOW-3: the check only works in one direction.** A subcommand built by an escape or interpolation fails closed, but an `"auth"` *first* element built the same way (`"\("auth")"`, or an invalid escape) is not flagged, so `run(["\("auth")", "token"])` passes. This is close to the documented "values built at run time" limit. Either document it explicitly, or flag a non-static literal followed by a known `gh auth` subcommand literal.

## PR58: install/uninstall/keyboard docs (docs-only). PASS

The diff changes `README.md` and `docs/install.md`. Claims checked against the source at 22c0264:

| Claim | Source | Result |
|---|---|---|
| macOS 13+ | `build-app.sh:76` `LSMinimumSystemVersion` 13.0 | ✔ |
| Universal; Intel smoke under Rosetta, not on PRs | `package-zip.sh` defaults to universal; workflow "Intel slice smoke (Rosetta)" runs only when `event_name != pull_request` | ✔ |
| Workflow "Swift", push to main, artifact `GitHubPet-app`, kept 90 days | `swift.yml:1,4-5,93,98` (90 for push, 14 for PRs) | ✔ |
| ZIP and `.sha256` names; `shasum -c` works | `package-zip.sh:7`; sidecar format `<hash>  <file>` | ✔ |
| Menu-bar app, no Dock icon | `LSUIElement` true, `.accessory`, `MenuBarExtra` | ✔ |
| Mascot near the bottom-right | `MascotWindow.swift:274-276` `defaultOrigin` | ✔ |
| Quit from the inbox power button | `InboxView.swift:191-192` | ✔ |
| Starts on Demo data; Settings → Data source "GitHub CLI (gh)" | `Settings.swift:52` `.fixtures`; Settings PNG label | ✔ |
| Privacy mode on by default; Show details | `Settings.swift:48` | ✔ |
| Settings in `dev.github-pet.GitHubPet`; `defaults delete` is a manual step | bundle id `build-app.sh:25`; normal launches use `.standard` (`LaunchOptions.swift:127`); no app code runs it | ✔ |
| Not yet opened at login | no `SMAppService`/`LoginItem` use in the app (PR57 is core-only) | ✔ (still true after PR57) |
| Mascot is one VoiceOver button that opens the inbox; not keyboard-focusable; live VoiceOver and keyboard unverified | render report `mascot AX: role=AXButton press=opens-inbox`; caveats are explicit | ✔ |
| Build-it-yourself paths | `package-zip.sh` → `.build/dist`; `build-app.sh` → `.build/app/GitHubPet.app`; `--universal` | ✔ |
| Gatekeeper flow ("Open Anyway"; Control-click no longer works on 15+) | matches Apple's current guidance; no quarantine removal is advised | ✔ |

**INFO:** step 4.1 and the uninstall section say "Bin". US-English macOS says "Trash", so consider "Trash (Bin)".

Uninstall step 4 will need updating when the login-item UI ships.
