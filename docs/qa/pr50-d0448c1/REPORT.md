# PR50 (#40) functional QA: sanitized custom mascot pack labels

Head **`d0448c17b49060797cfb5ebaaab905eb68d96b97`**. Verdict: **functional PASS for label sanitizing at d0448c1, with one open usability defect (directory path cap) that is being fixed. Not merge-ready while that fix is pending and CI is red.**

QA: Claude QA t4x (claude-opus-5-5). The evidence comes from actual built apps launched with `GITHUB_PET_PACK_DIR=<pack>` and `--render-snapshots <dir>`. That mode forces fixtures and a throwaway preferences suite, then quits by itself. No gh, real account or real preference changes, and no unit harness.

## Evidence chain

| Head | What ran | Where |
|---|---|---|
| `51bd398` | 15-case hostile sweep (QA t4x) | `docs/qa/pr50-51bd398/` |
| `33f36f1` | 18-case hostile sweep, including scalar-cap 256/257/300 (QA t4x) | `docs/qa/pr50-33f36f1/` |
| `d0448c1` | one pending-space boundary launch (Codex t55, saved app `/Users/chris/github-pet-builds/pr50-d0448c1`), visually and independently re-checked by t4x | this directory |

The `33f36f1`→`d0448c1` source delta is the single condition in `PackLabel.sanitize` that stops a pending space being kept at the 256-scalar boundary (plus tests). The 33f36f1 sweep results stand for every case that never reaches that boundary with a pending space. The full sweep was not re-run at d0448c1.

## Results

- **Single line, no injection** (33f36f1, 18/18): every launch printed exactly one `GitHubPet: mascot …` stderr line. Raw stderr bytes contain no C0/C1 controls, no ESC or 8-bit CSI (U+009B), and no CR/LF, U+2028/9, bidi overrides/isolates/marks, zero-width characters, BOM or soft hyphen. Injected text such as `GitHubPet: mascot pack trusted` stays inline on the same line and is never a separate line. A leftover visible `[31m` is inert text.
- **Fallback:** an empty id, or one that is empty after sanitizing (ESC, NUL, U+2028, bidi, ZWSP, whitespace), shows `(unnamed pack)`.
- **48-grapheme cap:** a 600-character ASCII id shows 48 graphemes plus `…`. A 120× family emoji id shows 48 graphemes plus `…`.
- **Scalar cap:** `a` + 300×U+0301 + `pack-B` ends in `…` and drops `pack-B`. Exactly 256 scalars shows all 256 with no `…`. 257 shows 256 plus `…`. At 51bd398 the same input was cut silently with no `…` (reproduced the Copilot finding); fixed at 33f36f1.
- **Pending-space boundary (d0448c1):** id `a` + 254×U+0301 + ` bc`. t4x re-parsed the raw `stderr.bin` independently: the label is `a` + 254×U+0301 + `…` (256 code points), with no space, no `bc` and no trailing `space…`. This equals Codex's recorded `displayed_label`. Exit 0, 208 PNGs.
- **Normal names unchanged:** `qa-normal-pack` is shown exactly. Zero-width-only noise is stripped to `abcdefg` as expected.
- **Pack loads with a hostile stored id:** every non-rejected case printed `loaded from` and rendered the custom pack's mascot (PNGs viewed: `boundary-pack-loaded-mascot.png`, `../pr50-33f36f1/scalar-cap-300-pack-loaded-mascot.png`, `../pr50-51bd398/how-to-pack-loaded-mascot.png`). The stored manifest id was written unchanged and loading accepted it. No in-app consumer of the id beyond display could be observed.
- **Error text sanitized where observable:** a frame path `../\n\e[2J‮evil.png` gives `pack rejected: unsafe path '../ [2Jevil.png'`. A frame path with ESC, newline and RTL gives the same kind of single-line clean text. The rejected pack falls back to the placeholder art (PNG viewed).
- **Isolation:** real `dev.github-pet.GitHubPet` preferences hash was unchanged for every launch. The saved b0127f0 app (pid 31897) was untouched. Each render launch leaves an empty 42-byte `dev.github-pet.render-snapshots.<pid>.plist`. That leftover was already on main and is not caused by PR50 (PR53 addresses it).

## Findings

1. **Defect, usability (both heads, fix in progress by t4z):** the pack **directory path** in the launch line also goes through the 48-grapheme label cap, for example `loaded from /private/tmp/claude-501/-Users-chris-github-pet-…`. Normal install paths are longer than 48 characters (`/Applications/GitHubPet.app/Contents/Resources/MascotPacks/mona-pet-v1` is 70), so the line loses the identifying tail, which defeats its purpose of showing which mascot is in use. A hostile directory name below that prefix cannot be inspected either. Main printed the full path. Re-verify on t4z's head: a long path must show its identifying tail and still have no controls or bidi characters.
2. **Accepted cosmetic limit:** ZWJ (U+200D) is a format character and is dropped, so emoji ZWJ sequences split into their parts (👨‍👩‍👧 → 👨👩👧). Not a security issue.
3. **Not reachable, informational:** hostile names for *extra* (non-required) states never reach error text, because the loader does not validate states it does not use. Required-state errors use fixed names.

## CI and limits

Current-head CI run 43782775647 is **RED**: `descendantHoldingThePipeDoesNotLeakReadsOrDescriptors` (`openDescriptors() → 11 <= before → 10`) in ProcessRunnerTests. This is the process-wide fd-count test under Developer triage. It is unrelated to this PR's files, but the PR is not green.

Limits: Settings shows the same `MascotPackError.description` strings, but the Settings view was not observed (no GUI control, Screen Recording or Accessibility in this session). The stderr line is the observed sink. No pointer, VoiceOver, live motion or physical Intel checks. The renders are offscreen, drawn by the app itself.
