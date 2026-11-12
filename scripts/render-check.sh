#!/bin/zsh
# GUI regression check: render the fixture scenario offscreen with the real SwiftUI/AppKit views
# (--render-snapshots) and assert on the report. Catches the collapsed-Inbox-list defect (#20),
# sticky partial status (#21), unknown-count badges and Demo labelling.
#
#   scripts/render-check.sh [path/to/GitHubPet executable] [output dir]
set -euo pipefail
cd "${0:A:h}/.."

binary=${1:-.build/app/GitHubPet.app/Contents/MacOS/GitHubPet}
out=${2:-.build/render-check}
suite=dev.github-pet.render-check.$$
rm -rf "$out"

"$binary" --defaults-suite "$suite" --reset-settings --fixtures --render-snapshots "$out" &
pid=$!
for _ in {1..90}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; echo "render-check: timed out" >&2; exit 1; fi
wait $pid || true
defaults delete "$suite" >/dev/null 2>&1 || true

report=$out/report.txt
[[ -f $report ]] || { echo "render-check: no report at $report" >&2; exit 1; }

failures=0
check() {
  if grep -qE -- "$2" "$report"; then echo "ok   $1"; else echo "FAIL $1 (expected /$2/)"; failures=$((failures + 1)); fi
}
# Inbox window must be tall enough to show the rows (collapsed list was 125 pt with 4 rows).
inbox_height() { grep -E "^$1-inbox: " "$report" | sed -E 's/.*x([0-9]+) pt/\1/'; }
for step rows in 01-baseline 3 02-injected 4; do
  height=$(inbox_height $step)
  min=$((100 + rows * 52))
  if (( ${height:-0} >= min )); then echo "ok   $step inbox height $height >= $min"
  else echo "FAIL $step inbox height ${height:-missing} < $min (rows collapsed?)"; failures=$((failures + 1)); fi
done
check "baseline count"            '^state=Up to date badge=3 rows=3 demo=true'
check "injected adds one row"     '^state=Up to date badge=4 rows=4 demo=true mood=attention'
check "replay adds nothing"       '^state=Up to date badge=4 rows=4 demo=true mood=idle'
check "partial is labelled"       '^state=Partial data badge=3\+ rows=3'
check "stale count unknown"       '^state=Stale badge=\? rows=4'
check "disconnect count unknown"  '^state=Error: simulated disconnect badge=\?'
check "menu-bar names Demo"       '^menu-bar AX: GitHub Pet, Demo data, '
check "partial AX quality"        'at least 3 items, some sources unavailable'
for png in 02-injected-inbox 04-partial-inbox 08-privacy-hover 05-stale-mascot; do
  [[ -s $out/$png.png ]] && echo "ok   $png.png rendered" || { echo "FAIL $png.png missing"; failures=$((failures + 1)); }
done

(( failures == 0 )) || { echo "render-check: $failures failure(s); see $out" >&2; exit 1; }
echo "render-check: all checks passed ($out)"
