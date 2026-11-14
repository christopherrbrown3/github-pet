# PR43 independent exact-head integration QA

Exact pushed head `561fafc6705b4e587aa23327fc029f965edac33a` (remote rechecked); CI [43608764228](https://github.com/christopherrbrown3/github-pet/actions/runs/43608764228) **SUCCESS**. **Verdict: PASS for scoped integration, packaging and provenance. No remaining reproducible scoped defect.** Clean-Mac quarantined installation/first launch, settings preservation on that path, physical Intel and manual desktop acceptance remain unverified. This is not release or installation sign-off.

Independent checks:

- Parents are accepted packaging head f1cfada8aeb28588e86952d39496f0cfeee03c34 and actual merged main b10d329e0036bc67a927a4b7e561765ef37312fd. Reconstructed automatic merge tree `c69eba8f2eab2696a11f9597e499e842ffaa70dc` equals candidate HEAD tree: no manual merge changes.
- Full-history commit count **70**. All Sources, Tests, assets and scripts/render-check.sh byte-identical to merged main: accepted PR36 incidents and PR42 hover fixes included unchanged.
- Packaging workflow, build/ZIP scripts, Intel smoke fix/regressions and install instructions byte-identical to accepted f1cfada. Prior independently verified D1/D2 guards, failed-child negative probe and push-only artifact lookup evidence retained; no unnecessary rerun or local universal rebuild.
- Developer's local .build/debug is stale for this SHA and was **not used**. No runtime/link result claimed from it. Actual green CI ZIP and its packaged-binary render report are the next evidence source.

## Actual green universal ZIP: PASS

QA used one bounded event wait on existing Developer watcher t2j, then independently downloaded **GitHubPet-app** (artifact14119543868, 14-day PR retention) from the exact new green run into a fresh empty directory. No Developer artifact or local build was reused.

- ZIP `GitHubPet-0.1.0-561fafc-universal.zip`.
- Independently computed SHA-256 matches shipped checksum: **`3fe3ec241d2e8ed06520ea041e889ed5fa1543441756dbea1719121a196e4074`**.
- Ditto-extracted app passes `codesign --verify --deep --strict --verbose=2`; signature is ad-hoc, TeamIdentifier unset. `lipo` confirms **x86_64 + arm64**.
- Signed Info.plist: version **0.1.0**, build **70**, full `GitHubPetSourceRevision=561fafc6705b4e587aa23327fc029f965edac33a`; bundle ID dev.github-pet.GitHubPet, minimum macOS13.0, LSUIElement true. Independent full-history count=70.
- Manifest and all 12 bundled mascot PNGs match exact source bytes.
- Actual CI log: combined-branch checkout `cc278a3` (561fafc into mainb10d329), **277 tests PASS**, then exact PR-head checkout561fafc for packaging. Provenance assertions, eight packaging regressions, universal package/bundle verification and render-check all PASS. The failed-child smoke regression reports child86→script86; child0→0. The actual Rosetta smoke step is excluded on PR events.

## Packaged incidents/hover integration: PASS

Independently downloaded the same run's **render-check** artifact. Workflow renders using the packaged app binary. Actual report confirms minor/major/critical incident tiers, service-only failure marked unavailable, quiet resolution to zero incidents; transparent/no-candidate diagnostic completion; repeated saved-edge and off-all-displays drops both inside/saved=shown/expected-origin; content growth repositions right→left with art/labels clear and on screen. Together with exact main source equality, this confirms PR36 incidents and PR42 hover fixes are present in the packaged build, not merely on an unrelated local branch.

Visually inspected only two new artifact images: major-incident hover and urgent128 right-edge placement composite. Incident line, separate item count and left-side fallback are retained. These are offscreen evidence; placement composite explicitly says window-bounds and depicts an arrow anchor, not actual captured native popover chrome. Prior exact-main still/behavior evidence remains supporting evidence; no new broad visual sweep.

Current-head Copilot review5905272144 reports no open issues and calls out real-desktop quarantined installation/settings-preservation limitations. CI's positive gesture execution is explicitly skipped because runner system Reduce Motion is ON, not counted as motion acceptance. No physical Intel run, clean-Mac quarantine test, manual pointer UX or live desktop motion claimed.

Logs, source validation, artifact summary, actual render report and two inspected PNGs are saved adjacent. No local app compilation, stale debug linking, broad local tests/render sweep, system/permission changes, merges, tags or releases. PM owns the exact-head merge decision and outstanding desktop/installation acceptance boundary.
