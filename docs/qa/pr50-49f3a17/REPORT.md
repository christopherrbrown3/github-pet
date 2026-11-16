# PR50 49f3a17 asset-error identification QA

**PASS for asset-error identification at `49f3a17c75d4a6e3d4d0da832a946782c9b30f7f`.**

- **Earlier defect fixed:** at 45befb4 the medium diagnostic defect made two missing assets display identically (`docs/qa/pr50-45befb4/asset-error-ci/REPORT.md`). That defect is resolved in the actual CI app.
- **Still safe:** rejection and the placeholder fallback still behave safely, and the displayed text remains sanitized.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task E from PM t61, 2026-11-16. This covers the single affected check only. The earlier hostile-pack, boundary and loaded-directory evidence was reused, not rerun.

## Merge review

`49f3a17` has two parents: `a1881806ce59a5fc15be8c1cd5bca0b47ad90876` (PR50 fix) and `b152656af3cd0e140a42e917973f084854ea3f75` (main, which includes the PR51 merge).

`git merge-tree --write-tree a188180 b152656` produces `b57ee1ac0a0ec6b4f1caad715fa1b6ea6ef64488`, which is **identical** to the tree of `49f3a17`. So the merge was a clean automatic merge, with no manual resolution and nothing beyond a188180 plus main.

Against main, PR50 still touches only four files:

- `AppModel.swift` (launch-line `sanitizePath`)
- `MascotPack.swift`
- `MascotPackTests.swift`
- `PackLabelTests.swift`

QA already source-reviewed a188180 with no blocker (`docs/qa/source-review-2026-11-16-pr50-a188180-pr59-d813f10.md`; LOW-1 and LOW-2 remain non-blocking).

## Artifact

| Item | Value |
|---|---|
| CI | 43884718129, completed SUCCESS on headSha 49f3a17… (`ci.json`) |
| Artifact | `GitHubPet-app` from that run, downloaded with gh (`artifact-metadata.json`) |
| ZIP SHA256 | `24af4ea48009c706e39e6849d758b0eaae272bec0e39a62aeba1423c6dc18efd` (matches the sidecar) |
| Binary SHA256 | `e374f54d7e3c61a56c299a4bc974f60c80fea9519ad8fdd058e06e759c8ad296` |
| Info.plist | `GitHubPetSourceRevision` = 49f3a17c75d4a6e3d4d0da832a946782c9b30f7f (**verified equal**), build 130 |
| Signature | `codesign --verify --deep --strict` PASS |

## Method and safety

- **Helper:** `scripts/qa/pr50-49f3a17-asset-pair.py`. It uses the same fixture and the same offscreen renderer mode as the 45befb4 run.
- **Fixture:** a copy of the bundled pack in which only the id/name and the idle frames/fallback were changed. The fallback points at two absent paths that share an 83-character prefix:
  - `frames/shared-diagnostic-prefix-shared-diagnostic-prefix-shared-diagnostic-prefix-/missing-alpha.png`
  - `frames/shared-diagnostic-prefix-shared-diagnostic-prefix-shared-diagnostic-prefix-/missing-beta.png`
- **Launch:** exactly one artifact launch, PID 98228, run as `--render-snapshots <fresh private dir> --fixtures` with `GITHUB_PET_PACK_DIR` set to the private fixture and a gh tripwire. It is an offscreen renderer, not a normal launch.
- **Exit:** the process exited normally with code 0 within the 300 s bound. There was no CUA, no signals and no quit.
- **gh tripwire:** not invoked.
- **Preferences:** the hash-only snapshots before and after show **no changed domains or files**. The 45befb4 run had left an empty `render-snapshots.<pid>` domain; that did not happen this time.
- **Protected app:** PID 31897 kept its original path and start time. Afterwards no other GitHubPet process was running.

## Observed result

| Check | 45befb4 (before) | 49f3a17 (now) |
|---|---|---|
| file-not-found errors in the stderr rejection line | 2 | 2 |
| Distinct displayed paths | **1** (both shown as `frames/shared-diagnostic-prefix-shared-diagnosti…`) | **2** (full paths ending `missing-alpha.png` and `missing-beta.png`) |
| Control/format/separator characters in the line | none | none |
| Settings rejection text (`settings.png`, viewed) | the same truncated path twice | names both full paths, ending `/missing-alpha.png` and `/missing-beta.png`, in readable orange wrapped text inside the Mascot section |
| Fallback (`01-baseline-mascot.png`, viewed) | purple native placeholder, Demo, badge | purple native placeholder, DEMO label, badge 3: the custom pack is safely rejected |

Raw line:

`GitHubPet: mascot placeholder (pack rejected: file not found '…/missing-alpha.png'; file not found '…/missing-beta.png')`

The only other stderr lines are the two existing "hover summary has no clear placement" renderer messages, which also appeared in the 45befb4 run, and the snapshots-written line.

## Limits

- **Elision path not exercised:** both fixture paths are shorter than 160 graphemes, so the head…tail elision in `sanitizePath` is not used here. The Developer's PackLabel tests cover that, with distinct tails on a 300+ character shared prefix.
- **Open lows:** the LOW-1 collision (paths over 2048 scalars, or paths that differ only in the elided middle) and LOW-2 (unbounded joined length) are still open and non-blocking.
- **What was judged:** only the rejection line, `settings.png` and `01-baseline-mascot.png`. The renderer wrote 215 PNGs, and no broad renderer acceptance is claimed.
- **Not covered:** native window, VoiceOver, live account, network, Intel and clean-install evidence.

## Evidence committed

- **Top level:** `ci.json`, `artifact-metadata.json`, `provenance.json`.
- **missing-pair/:** `fixture.json`, `pack/manifest.json`, `launch.json`, `stderr.bin`, `rejection-analysis.json`, `completion.json`, `before.json`, `after.json`, `snapshots/settings.png`, `snapshots/01-baseline-mascot.png`.
- **Kept local only:** the ZIP, the extracted app, the pack frames and the other PNGs.
