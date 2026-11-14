# PR43 independent exact-head QA checkpoint

Head `f54d5a6deb1db6c6ec3e87361431d4222dbd6a64`, CI run `43606183925`.

Pending actual green CI artifact verification. Not accepted on developer local evidence.

Completed: unchanged exact-head detached checkout; source delta review; six developer packaging regressions independently rerun; two additional missing-Git entry-point guards; complete-history count independently verified as 51; shell syntax and diff whitespace checks pass. No local app compilation. Full/depth-1/depth-2 fixture clones exercise both build and packaging entry points; shallow/missing history is rejected before Swift or build output.

Copilot 4572352217: CLI lookup adds `--event push`, main and success filters; null/empty run guard prevents downloading without a match. Browser instructions also identify repository main push runs. Actual filtered read-only lookup returned push run 43533179320 at main 83b7b5c; no download from that old pre-packaging run was claimed.

Copilot 4572352235 / QA D1: both CI checkouts fetch full history; combined-branch build/tests precede a PR-head checkout for packaging/rendering. Expected SHA, non-shallow history and count >1 assertions precede packaging. Build guard tests depth 2 as well as depth 1, so count >1 alone cannot hide a truncated checkout. Signed plist now includes full `GitHubPetSourceRevision`, checked after archive extraction.

Development Gatekeeper advice now links install.md's Open Anyway flow and explicitly states clean-Mac quarantined first launch remains unverified. No quarantine, system settings or permission changes; no physical Intel or clean-Mac acceptance claimed.
