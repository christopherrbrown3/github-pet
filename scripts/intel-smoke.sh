#!/bin/zsh
# Smoke-test the x86_64 slice of the packaged app under Rosetta: launch it in snapshot mode
# (Demo fixtures, throwaway preferences) and require a scenario report. Without Rosetta, says
# SKIP rather than passing.
#
#   scripts/intel-smoke.sh [path/to/GitHubPet.app]
set -euo pipefail
cd "${0:A:h}/.."

app=${1:-.build/app/GitHubPet.app}
binary=$app/Contents/MacOS/GitHubPet
out=.build/intel-smoke
[[ " $(lipo -archs "$binary") " == *" x86_64 "* ]] || { echo "intel-smoke: $binary has no x86_64 slice" >&2; exit 1; }
if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "SKIP intel-smoke: Rosetta is not installed here; the x86_64 slice was built but not run"
  exit 0
fi
rm -rf "$out"
GITHUB_PET_GH_PATH=/nonexistent/gh arch -x86_64 "$binary" --render-snapshots "$out" &
pid=$!
for _ in {1..240}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; echo "intel-smoke: timed out" >&2; exit 1; fi
wait $pid || {
  result=$?
  echo "intel-smoke: x86_64 slice exited unsuccessfully ($result)" >&2
  exit "$result"
}
grep -q '^## 01-baseline' "$out/report.txt" && grep -q '^state=Up to date badge=3 rows=3 demo=true' "$out/report.txt" \
  || { echo "intel-smoke: no usable report from the x86_64 slice" >&2; exit 1; }
echo "intel-smoke: x86_64 slice ran the snapshot scenario under Rosetta"
