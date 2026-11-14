# PR48 original-head JSON validation defect — independently confirmed

Exact **`940231dc1a794dcf221449e8df1a441718b1ca3f`**; hold for already-dispatched byte-validation rework (Copilot4575503024).

QA extended only the bounded original-head probe to `JSONSerialization.data` → actual `ScopedResponseParser.parse`, using exact old MonitoringScope/ScopedGitHub/CommandBudget/GitHubCLI declarations compiled in a temporary QA executable. Only module imports were added to supply unchanged47 model dependencies. No mutable48 source/object or user state was modified; no transport/UI operation or broad suite ran.

For **LF, CR, CRLF, NEL, LS and PS**:

- A selected repository's metadata ID `R_fixture<suffix>` is accepted and yields **complete=true**, contrary to strict metadata validation.
- A fresh Everything response viewer ID `U_fixture_A<suffix>` is retained in ScopeAccount and yields **complete=true**, contrary to raw ID validation.
- The same raw native-string ScopeAccount constructor rejects those suffixes. Prior raw-constructor non-reproduction was accurate for that path but insufficient to characterize the response parser.
- Selected expected-account handling still returns **identityMismatch and zero rows** for the suffixed viewer ID; no submitted-scope rows leak in this probe.

Controls: one real selected target, two source aliases, valid response complete=true; empty and punctuation metadata IDs reject as malformedTarget. Result: metadata6/6 accepted, fresh viewer6/6 accepted, selected mismatch-discard6/6. Reproduction matches Developer's separate completed-old-module evidence. **The mechanism behind native-string versus JSON-path differences is not proven**; no standalone regex result is substituted for actual parser behavior.

Evidence: json-validation.log, source hashes and scripts/qa/pr48-json-validation.*. These are negative-before results, **not PR48 acceptance**. Re-run the full response path after the byte-validation fix/new integrated exact SHA; original CI remains failed and provides no app/render artifact.
