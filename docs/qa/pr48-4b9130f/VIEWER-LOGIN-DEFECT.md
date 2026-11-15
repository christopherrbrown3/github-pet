# PR48 exact4b viewer compatibility QA — FAIL / HOLD

Head **`4b9130f82b1299929b1bc0c14d1f446cab4f91a1`**. Independent bounded normal-import parser fixtures, no live authentication:

- Valid viewer node ID `U_fixture_A`, login `fixture-user`: **complete=true** in Everything and selected modes (positive controls).
- Same valid ID with `fixture-user_demo` or `demo_admin`: **viewerUnavailable, viewer=nil, complete=false** in both modes (four compatibility failures).

Viewer display login is being checked with organization-target grammar, which excludes underscores. GitHub's official documentation confirms underscore+shortcode managed usernames and shortcode_admin setup accounts on github.com, within39 characters. [GitHub Docs: external-authentication usernames](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-iam/iam-configuration-reference/username-considerations-for-external-authentication).

Fix only viewer-display validation; retain organization/repository target grammar, strict node-ID/account identity and selected expected-account mismatch behavior. Normal account display remains a positive control. No UI/query/ID grammar expansion is requested.

Evidence: viewer-login-before.log, scripts/qa/pr48-viewer-login.swift. Exact held source/build HEAD and unchanged module/object hashes checked. Temporary executable removed; **all4b links explicitly released to Developer before mutation**. Scoped errors44 assertions and earlier unaffected checks remain valid. Current4b CI helper is supporting only; no superseded-head acceptance. Await new exact held SHA and focused viewer/absence/control/mismatch positive-after checks plus new CI.
