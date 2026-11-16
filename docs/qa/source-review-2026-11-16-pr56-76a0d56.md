# QA review: PR56 round 2, 76a0d56 (test-only token-access scanner)

**Source review PASS.** QA's MED-1, LOW-2 and LOW-3 are all fixed and verified. Two new LOW limits remain, both non-blocking. No functional run was needed because the PR is test-only.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task K from PM t61, 2026-11-16.

- **Head and CI:** `76a0d56e80f5438824d2269de59cd44bdf017e00`. CI 43893328274 completed SUCCESS on the exact head.
- **Merge `f432bcd`:** parents cce3df0 and main 5cf5185. `git merge-tree` gives `1bd5c9d…`, identical to its tree. Against main, the only change is `Tests/GitHubPetCoreTests/TokenAccessSourceTests.swift`.

## Fixes reviewed

- **MED-1 (`statusFlagViolations`):** after `"auth", "status"`, every later element of the same array literal must be a static literal, up to `]`.
  - It rejects `--show-token*` and any short-flag group containing `t` (`-t`, `-at`). The pflag grouping is handled.
  - An escaped literal or a non-literal in that array is a violation.
  - The documented preflight (`--active --hostname github.com`) and a trailing comma are still allowed.
- **LOW-2:** `oauth_token`, `hosts.yml`, `find-generic-password` and `find-internet-password` were added to the forbidden substrings. They are matched in the raw text and in decoded literals, so `hosts\u{2E}yml` is caught.
- **LOW-3:** a non-static first element (an interpolation or invalid escape) followed by a known `gh auth` subcommand that is an array element (followed by `,` or `]`, not a dictionary `:`) fails closed.
- **Lexer change:** interpolation code is now lexed into separate segments that are appended after the top-level tokens. That prevents nested tokens from changing which elements sit next to each other, which is correct. The `]` token gives the status check its array boundary.
- **Tests:** the new tests cover each finding plus allowed controls, including ordinary interpolated text and dictionary keys.

## Re-probe (verbatim `violations(in:)` in a scratch build; nothing committed)

| Input | Result |
|---|---|
| `["auth","status","-t"]` (old MED-1) | `gh auth status -t` ✔ |
| `["config","get","oauth_token"]`, `security find-generic-password …`, `…/hosts.yml` (old LOW-2) | flagged ✔ |
| `["\("auth")","token"]`, `["au\qth","token"]` (old LOW-3) | `gh <escaped literal> token` ✔ |
| `"--sho\u{77}-token"`, multiline `"""-t"""` (new) | flagged ✔ |
| Documented preflight | allowed ✔ |
| **Current Sources at 76a0d56** (45 files) | **0 violations**, `"auth", "status"` preflight present (1) ✔ |

New evasions that still pass:

- **LOW-A: run-time construction of the auth arguments.** All of these are inside the documented "values built at run time" or "same array literal only" limits:
  - array composition: `["auth","status"] + ["-t"]`, `.append("-t")`
  - wrapped first elements: `[String("auth"), "token"]`, `["AUTH".lowercased(), "token"]`, `[x ? "auth" : "api", "token"]`

  Optional tightening: flag any array or statement in which a literal `auth` (any case) appears together with a later `gh auth` subcommand literal other than `status`, or a `-t` literal.
- **LOW-B: older Keychain APIs.** `SecKeychainFindInternetPassword`/`SecKeychainFindGenericPassword` and `kSecReturnData` queries are not forbidden; only `SecItemCopyMatching` is. Consider adding `SecKeychainFind` and `kSecReturnData`. `git grep` finds none of them in Sources today.
