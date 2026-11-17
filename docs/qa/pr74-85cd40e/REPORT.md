# PR74 85cd40e QA: #60 low batch

**PASS for all four items.** C1 is confirmed fixed on the exact-head artifact. One LOW remains on the scanner.

QA: Claude Opus 5.5 (`claude-opus-5-5`), task AD from PM t61, 2026-11-17.

- **Head and CI:** `85cd40ec1b3d6fe54de27469b5f6b497e4a05f69` contains main 55ff7a3. CI 44152200929 completed SUCCESS on the exact head. There are four commits, one per item.
- **Gate:** the developer's gated full suite passes 560 tests in 92 suites, and the descriptor test passes in isolation.

## (1) 2eeda13: baseline write-skip

`EventBaselineStore.save` skips a write only when `sameContent`: the record equals the last saved one with `lastSuccess` ignored, **and** the new `lastSuccess` is not earlier and is less than 10 minutes newer.

- **Content changes save immediately:** a change to seen digests, `baselineEstablished` or `quality` is never "same content", and nor is a nil transition or a backwards `lastSuccess`. ✔
- **24 h window:** the saved `lastSuccess` lags by at most 10 minutes. On a relaunch `InboxEngine` compares `now - restoredLastSuccess <= 24 h`, so a stale time can only make the window **shorter** by ≤ 10 minutes. The failure mode is a silent re-baseline, never a burst. ✔
- **Quit:** there is **no final save on terminate** (`applicationWillTerminate` only cleans up the simulation). Nothing material is lost, because all content changes were already written, and only up to 10 minutes of `lastSuccess` advance is dropped (as above). Acceptable.
- **Fail-before:** `unchangedContentIsNotRewrittenEveryPoll` reports 2 issues before the fix. This also addresses QA's PR71 observation that Chris's running build rewrote its plist about every 2 minutes.

## (2) 19b1d5d: scanner, Security framework reads

- **Added:** `SecKeychainFind` (Generic and Internet password), `SecKeychainItemCopyContent` and `kSecReturnData`. `SecItemCopyMatching` was already forbidden, so every modern Keychain read is caught anyway.
- **False positives:** these are raw-text substring checks, so a comment mentioning them would be flagged. That fails closed, and nothing in Sources contains them today.
- **Fail-before:** 5 issues.
- **LOW (false negatives):** the legacy `SecKeychainItemCopyAttributesAndData` (which can return item data) and the `security dump-keychain -d` CLI aren't listed. Consider adding `SecKeychainItemCopyAttributesAndData` and `dump-keychain`.

## (3) 8c564df: `--exclude-drafts`

- **Docs:** `docs/install.md` now runs `gh release list … --exclude-drafts --limit 1`. QA earlier ran the equivalent read-only command, and it returns `v0.1.0-beta.1`.
- **Guard:** `InstallDocsTests` requires `--exclude-drafts` on every `gh release list` line in the guide. It is line-based and strict.
- **Fail-before:** only a note (`fail-before-3-docs-NOTE.txt`: 1 issue on the unchanged line, console output not saved). That's acceptable for a docs guard.

## (4) 85cd40e: C1 stale status cleared on an identity change

- **Code:** `ScopeEditor.observeActive` sets `status = nil` on an identity change. With a dirty draft or an interrupted validation, it then reports "Account or data source changed… nothing was applied." for the new account.
- **Fail-before:** `accountChangeClearsTheOldAccountsStatusLine` fails before the fix, with the old "3 found…" status kept.
- **Functional:** built-in `settings-discovery-identity-mismatch`, the same flow that first showed C1 at e57d1f3 and 3f89207, on the exact-head artifact.
  - **Artifact:** ZIP `7c6b64a58b6c6a271f505f1c486ec2fda31757e52799b98728b68202c7ad7521` matches the sidecar. The revision is 85cd40e (build 235), and strict codesign passes.
  - **Launch:** `--simulate-monitoring-scope` first, with the **15015 guard**: protected app unchanged, gh tripwire 0, preferences hash-equal.
  - **Steps 00–05:** unchanged (Find, mismatch discards, find again).
  - **Steps 06–07 (switch to account B):** `status` is **None**, where 3f89207 showed the stale "Suggestions: organizations 3 found…". The step-07 Settings PNG (viewed) shows only "Suggestions not loaded." for `demo-b_sim`. **C1 fixed.**

Evidence: `ci.json`, `artifact-metadata.json`, `provenance.json`, `functional/{completion,progress,provenance,preferences-*}.json`, the records and the step-07 scope PNG.
