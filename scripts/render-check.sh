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
rm -rf "$out"

# Snapshot mode must ignore saved settings and leave them alone. Seed a test preferences suite
# with a live source and privacy off, point the app at it with --defaults-suite and --gh, then
# check the render used Demo fixtures with default privacy and the suite is unchanged. (The app's
# real preferences domain is never touched: a running copy of the app may be writing to it.)
suite=dev.github-pet.render-check.$$
scratch=$(mktemp -d)
trap 'defaults delete "$suite" >/dev/null 2>&1 || true' EXIT
seed=$(printf '%s' '{"schemaVersion":1,"dataSource":"githubCLI","privacyMode":false}' | xxd -p | tr -d '\n')
defaults write "$suite" GitHubPet.settings.v1 -data "$seed"
# Key-sorted dump: the exported plist's byte order is not stable.
prefs() { defaults export "$suite" "$scratch/$1.plist" && plutil -p "$scratch/$1.plist"; }
before=$(prefs before)

GITHUB_PET_GH_PATH=/nonexistent/gh "$binary" --defaults-suite "$suite" --gh --render-snapshots "$out" &
pid=$!
for _ in {1..90}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; echo "render-check: timed out" >&2; exit 1; fi
wait $pid || true
after=$(prefs after)

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
if [[ $before == "$after" ]]; then echo "ok   saved preferences untouched"
else echo "FAIL snapshot run changed saved preferences"; failures=$((failures + 1)); fi
# Settings opened as a bare title bar (520x16 pt content) before the Form got a minimum height.
settings_height=$(grep -E '^settings: ' "$report" | sed -E 's/.*x([0-9]+) pt/\1/')
if (( ${settings_height:-0} >= 660 )); then echo "ok   settings window height $settings_height >= 660"
else echo "FAIL settings window height ${settings_height:-missing} < 660 (collapsed?)"; failures=$((failures + 1)); fi
check "forces fixtures, default privacy" '^source=fixtures privacy=true details=false inbox-privacy=true'
check "details shown for the session"   '^source=fixtures privacy=true details=true inbox-privacy=false'
check "baseline count"            '^state=Up to date badge=3 rows=3 demo=true'
check "injected adds one row"     '^state=Up to date badge=4 rows=4 demo=true mood=attention'
check "replay adds nothing"       '^state=Up to date badge=4 rows=4 demo=true mood=attention'
check "partial is labelled"       '^state=Partial data badge=3\+ rows=3'
check "stale count unknown"       '^state=Stale badge=\? rows=4'
check "disconnect count unknown"  '^state=Error: simulated disconnect badge=\?'
check "mascot is one AX button"    '^mascot AX: element=true role=AXButton press=opens-inbox label=GitHub Pet, Demo data, '
check "mascot drag vs click"       '^mascot pointer: drop-without-drag-events=moved click=opens-inbox'
check "menu-bar names Demo"       '^menu-bar AX: GitHub Pet, Demo data, '
check "partial AX quality"        'at least 3 items, some sources unavailable'
check "loading count unknown"     '^state=Loading… badge=\? rows=0'
check "urgent fixture"            'mood=urgent'
check "attention static pose"     '^state=Up to date badge=5 rows=5 demo=true mood=attention'
check "mascot panel has tag lane" '^10-urgent-static-mascot: 128x150 pt'
check "missing gh named"          '^state=GitHub CLI not found badge=\? rows=0'
check "missing gh is not demo"    '^menu-bar AX: GitHub Pet, count unknown, GitHub CLI not found'
for png in 02-injected-inbox 04-partial-inbox 04-partial-inbox-dark 08-privacy-hover 05-stale-mascot \
           05-stale-mascot-dark 10-urgent-static-mascot 00-loading-inbox settings settings-dark; do
  [[ -s $out/$png.png ]] && echo "ok   $png.png rendered" || { echo "FAIL $png.png missing"; failures=$((failures + 1)); }
done

(( failures == 0 )) || { echo "render-check: $failures failure(s); see $out" >&2; exit 1; }
echo "render-check: all checks passed ($out)"
