# PR50 current-CI asset-error identification

**FAIL for asset-error identification at45befb4e1d4f30acfd826db47ba82c75e94431b6.** Medium diagnostic-usability defect: two distinct missing asset filenames become identical in the actual Settings rejection text and raw rejection log. No security bypass, unsafe loading or crash observed. Safe rejection/placeholder fallback and display sanitization PASS for this case. This narrows the earlier45befb4 functional PASS: seven loaded-directory cases remain valid, but they did not cover identification of failing asset paths.

## Provenance and bounded method

Actual green CI43799845701 artifact14195737979 GitHubPet-app. Workflow and artifact metadata both identify45befb4. ZIP SHA25650750721c65fc9d8c1c19924c542071a12c20fa7df4613a557be76529f435e4f matches sidecar; embedded full revision matches; strict deep signature verification passed. Binary SHA256bcf847d603684c8c9fc57060e72a0244380f6808f07432588e76daeb12a6ff9f.

Read validator before launch: validateReading accumulates errors and uses a checked set for each distinct path; it does not stop at the first missing file. One copied bundled-pack fixture changed only invented id/name and idle frame/fallback references, preserving other valid assets. Both absent paths are safe relative .png references sharing an 83-character prefix:

- `frames/shared-diagnostic-prefix-shared-diagnostic-prefix-shared-diagnostic-prefix-/missing-alpha.png`
- `frames/shared-diagnostic-prefix-shared-diagnostic-prefix-shared-diagnostic-prefix-/missing-beta.png`

One actual-app launch only, PID71850, explicit --render-snapshots <fresh private output> --fixtures, GITHUB_PET_PACK_DIR points to private fixture, gh tripwire. One helper t5w;300s process bound; normal exit0 before the bound. No second launch, default launch, CUA, source/unit/build or control reruns. Source/CLI exposes no smaller snapshot mode. Existing renderer produced199PNGs, but only Settings and baseline placeholder were judged; no broad renderer acceptance claimed.

## Actual observed result

Raw stderr contains exactly one mascot rejection line with two file-not-found errors, both showing:

`frames/shared-diagnostic-prefix-shared-diagnosti…`

Neither missing-alpha.png nor missing-beta.png survives. Exactly2missing-file descriptions,1distinct displayed path. The launch line contains no control/format/line-separator characters. This is a real missingFile branch, unlike the older error-missing fixture which actually reached unsafePath because its path contained controls.

Viewed actual current-artifact snapshots/settings.png: the orange rejection message shows the same duplicate truncated path twice. Text is readable and wraps within its section; this is not merely an offscreen container clipping problem. The distinguishing filenames are absent from the message itself. Viewed snapshots/01-baseline-mascot.png: purple native placeholder with Demo label and fixture badge, confirming rejected custom pack fallback.

Expected diagnostic behavior: users can identify which of these two different referenced assets is missing. Observed: the log and Settings cannot distinguish them. The pack still rejects safely; stored path validation/loading behavior is not shown to be wrong.

Source context only, not a substitute for the observations: MascotPackError.description routes all file errors through the48-grapheme PackLabel.sanitize; the newer160-grapheme sanitizePath is used only for AppModel loaded-directory logging. Developer owns any fix/regressions; QA made no production change.

## Isolation and limits

Hash-only before/after: real dev.github-pet.GitHubPet domain, real plist, its2existing frame keys and NSGlobalDomain/frame hash unchanged. All existing domains/plists unchanged. Saved31897 retained original b0127f0 path/startNov14 12:44:32. Own71850 absent after normal renderer exit. Gh tripwire zero.

Known pre-existing source behavior: one new dev.github-pet.render-snapshots.71850 domain/plist,42bytes and0keys, empty binary-plist hash9261ecceda608ef174256e5fdc774c1e6e3dcf533409c1bc393d490d01c713f1. Preserved; no cleanup or preference restoration. This is separate from the diagnostic defect and from the disclosed earlier PR51 QA launch incident.

Only actual raw rejection line, necessary Settings PNG and placeholder PNG judged. No native pointer/VoiceOver/live account/network/Intel/clean-install evidence; gh tripwire is not socket monitoring. No other error branches/current-artifact controls claimed. Existing18/7-case captures and boundary/hostile-label evidence reused without rerun.

Evidence: provenance.json; missing-pair/fixture.json, pack/manifest.json, launch.json, stderr.bin, rejection-analysis.json, completion.json, hash-summary.json; selected snapshots/settings.png and01-baseline-mascot.png. All generated files retained locally. No source patch or additional launch. Report to PM for disposition; hold.
