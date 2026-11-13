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

# A one-day app-clock offset: everything time-based must follow the app clock, not the wall clock.
GITHUB_PET_GH_PATH=/nonexistent/gh "$binary" --defaults-suite "$suite" --gh --clock-offset 86400 --render-snapshots "$out" &
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
# The lines of one scenario's "## <name>" block, up to the next "## " header.
section() { awk -v name="## $1" '$0 == name { on = 1; next } /^## / { on = 0 } on' "$report"; }
# Like check, but only within one scenario, so a match from another step can't satisfy it.
check_in() {
  if section "$1" | grep -qE -- "$3"; then echo "ok   $2 [$1]"
  else echo "FAIL $2 [$1] (expected /$3/ in its section)"; failures=$((failures + 1)); fi
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
check_in 00-loading "forces fixtures, default privacy" '^source=fixtures privacy=true details=false inbox-privacy=true'
check_in 01b-details "details shown for the session"   '^source=fixtures privacy=true details=true inbox-privacy=false'
check_in 01-baseline "baseline count"            '^state=Up to date badge=3 rows=3 demo=true'
check_in 02-injected "injection uses the app clock" '^injected-age-on-app-clock=[0-9]s$'
check_in 02-injected "injected adds one row"     '^state=Up to date badge=4 rows=4 demo=true mood=attention'
check_in 03-replayed "replay adds nothing"       '^state=Up to date badge=4 rows=4 demo=true mood=attention'
check_in 04-partial "partial is labelled"       '^state=Partial data badge=3\+ rows=3'
check_in 05-stale "stale count unknown"       '^state=Stale badge=\? rows=4'
check_in 06-disconnected "disconnect count unknown"  '^state=Error: simulated disconnect badge=\?'
check_in 01-baseline "mascot is one AX button"    '^mascot AX: element=true role=AXButton press=opens-inbox label=GitHub Pet, Demo data, '
check_in 00-loading "mascot drag vs click"       '^mascot pointer: drop-without-drag-events=moved click=opens-inbox'
# Hover summary beside the character (#27 with #28 metrics): every case shows the real panel and
# popover on screen; worst gap to any frame <= 12 pt, no overlap, tags clear, on screen.
hover_lines=$(grep -E '^hover [a-z]+-[0-9]+-' "$report" || true)
hover_count=$(printf '%s\n' "$hover_lines" | grep -c . || true)
if (( hover_count >= 11 )); then echo "ok   $hover_count hover placements measured"
else echo "FAIL only $hover_count hover placements measured"; failures=$((failures + 1)); fi
while IFS= read -r line; do
  [[ -n $line ]] || continue
  name=${${line#hover }%%:*}
  worst=$(sed -E 's/.* window-gap-max=([0-9.]+|none) .*/\1/' <<< "$line")
  arrow=$(sed -E 's/.* arrow-anchor-to-static-art=([0-9.]+|none) .*/\1/' <<< "$line")
  if [[ $line == *" overlap=0 "* && $line == *" lane=clear "* && $line == *" on-screen=true "* \
        && $worst != none && $arrow != none ]] && (( ${worst%.*} < 12 || ${worst} == 12.0 )) \
        && (( ${arrow%.*} < 12 || ${arrow} == 12.0 )); then
    echo "ok   hover $name: worst window-boundary gap $worst pt, arrow anchor $arrow pt from art, no overlap, tags clear"
  else
    echo "FAIL hover $name: $line"; failures=$((failures + 1))
  fi
done <<< "$hover_lines"
for size in 64 128 256; do
  check "labels fit at $size" "^tags @$size: .* fits=true"
done
for step in '128->64' '64->256' '256->128'; do
  check "resize $step follows Settings, ground fixed" "^resize $step: .* ok=true"
done
for step in '128->256' '256->64'; do
  check "slider $step follows Settings, ground fixed" "^slider $step: .* ok=true"
done
check_in 01-baseline "menu-bar names Demo"       '^menu-bar AX: GitHub Pet, Demo data, '
check_in 04-partial "partial AX quality"        'at least 3 items, some sources unavailable'
check_in 00-loading "loading count unknown"     '^state=Loading… badge=\? rows=0'
check_in 10-urgent-static "urgent fixture"            'mood=urgent'
check_in 09-attention-static "attention static pose"     '^state=Up to date badge=5 rows=5 demo=true mood=attention'
check "mascot panel has tag lane" '^10-urgent-static-mascot: 128x151 pt'
check_in 11-gh-override "missing gh named"          '^state=GitHub CLI not found badge=\? rows=0'
check_in 11-gh-override "missing gh is not demo"    '^menu-bar AX: GitHub Pet, count unknown, GitHub CLI not found'
for png in 02-injected-inbox 04-partial-inbox 04-partial-inbox-dark 08-privacy-hover 05-stale-mascot \
           05-stale-mascot-dark 10-urgent-static-mascot 00-loading-inbox settings settings-dark \
           lane-64-99plus lane-128-99plus lane-256-99plus lane-64-99plus-dark; do
  [[ -s $out/$png.png ]] && echo "ok   $png.png rendered" || { echo "FAIL $png.png missing"; failures=$((failures + 1)); }
done

(( failures == 0 )) || { echo "render-check: $failures failure(s); see $out" >&2; exit 1; }
echo "render-check: all checks passed ($out)"
