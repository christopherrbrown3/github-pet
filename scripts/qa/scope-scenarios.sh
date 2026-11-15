#!/bin/zsh
# Functional QA driver for the offline monitoring-scope mode (PR49, issue #30).
#
#   scripts/qa/scope-scenarios.sh <full-sha> [scenario|file.json ...]
#
# Without scenarios: isolation baseline only. Launch --simulate-monitoring-scope, idle,
# quit normally, and check isolation. With scenarios: run each through the app's QA
# scenario runner and check isolation plus output structure.
#
# This script records evidence and checks isolation and structure mechanically. It never
# decides product correctness from the runner's own claims. QA judges each step's JSON and
# PNG against docs/monitoring-scope-application.md by hand.
#
# Env overrides (runner flags may change when the runner lands):
#   QA_SIM_FLAG       default --simulate-monitoring-scope
#   QA_SCENARIO_FLAG  default --qa-scenario
#   QA_OUTPUT_FLAG    default --qa-output
#   QA_IDLE_SECS      isolation-only idle time before quit (default 20)
#   QA_TIMEOUT_SECS   per-scenario wall limit before a normal quit is requested (default 180)
#   QA_LABEL          output subfolder for the isolation-only run (default isolation-baseline)
#   QA_PRIVACY_NAMES  extra regex of names that must never appear when privacy is on
set -uo pipefail

qa_root=${0:A:h:h:h}
sha=${1:?usage: scope-scenarios.sh <full-sha> [scenario ...]}; shift
[[ $sha =~ '^[0-9a-f]{40}$' ]] || { echo "need a full 40-hex SHA, got $sha" >&2; exit 64; }
short=${sha[1,7]}
sim_flag=${QA_SIM_FLAG:---simulate-monitoring-scope}
scenario_flag=${QA_SCENARIO_FLAG:---qa-scenario}
output_flag=${QA_OUTPUT_FLAG:---qa-output}
idle=${QA_IDLE_SECS:-20}
limit=${QA_TIMEOUT_SECS:-180}
verify=${qa_root:h}/qa-verify-$short
evidence=$qa_root/docs/qa/pr49-$short
mkdir -p "$evidence"
summary=$evidence/summary-$(date +%Y%m%dT%H%M%S).md
failures=0

note() { print -r -- "$*" | tee -a "$summary"; }
fail() { failures=$((failures + 1)); note "- FAIL: $*"; }
pass() { note "- ok: $*"; }

note "# PR49 scope functional run, $short"
note ""
note "SHA $sha. Started $(date -u +%FT%TZ). Mechanical checks only; product verdicts are QA's manual judgement of each step's JSON+PNG."

# 1. Fresh worktree pinned to the exact SHA. Reuse only if it is exactly that SHA and clean.
git -C "$qa_root" fetch -q origin || { echo "fetch failed" >&2; exit 69; }
git -C "$qa_root" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "unknown commit $sha" >&2; exit 65; }
if [[ -d $verify ]]; then
  [[ $(git -C "$verify" rev-parse HEAD) == "$sha" && -z $(git -C "$verify" status --porcelain) ]] \
    || { echo "$verify exists but is not a clean checkout of $sha; refusing to reuse" >&2; exit 65; }
else
  git -C "$qa_root" worktree add -q --detach "$verify" "$sha" || exit 70
fi
app=$verify/.build/app/GitHubPet.app
binary=$app/Contents/MacOS/GitHubPet
if [[ ! -x $binary || ${QA_REBUILD:-0} == 1 ]]; then
  (cd "$verify" && zsh scripts/build-app.sh release) > "$evidence/build.log" 2>&1 \
    || { echo "build failed; see $evidence/build.log" >&2; exit 70; }
fi
[[ $(/usr/libexec/PlistBuddy -c 'Print :GitHubPetSourceRevision' "$app/Contents/Info.plist") == "$sha" ]] \
  || { echo "built app revision does not match $sha" >&2; exit 70; }
binary_hash=$(shasum -a 256 "$binary" | cut -d' ' -f1)
note "Binary: \`$binary\`, sha256 \`$binary_hash\`, archs $(lipo -archs "$binary")."

quitter=$evidence/.tools/quit-pid
if [[ ! -x $quitter ]]; then
  mkdir -p "${quitter:h}" && swiftc -O -o "$quitter" "$qa_root/scripts/qa/quit-pid.swift" 2>"$evidence/.tools/quit-pid.log" || exit 70
fi

# A fake gh, first on PATH and as GITHUB_PET_GH_PATH: any gh launch is recorded even if
# polling misses a short-lived child. It fails without touching the network.
tripwire=$evidence/.tools/tripwire
mkdir -p "$tripwire"
cat > "$tripwire/gh" <<EOF
#!/bin/sh
echo "\$\$ \$PPID \$*" >> "$tripwire/invocations.log"
exit 1
EOF
chmod +x "$tripwire/gh"

real_plist=$HOME/Library/Preferences/dev.github-pet.GitHubPet.plist
snapshot() {  # $1 = output prefix
  defaults domains | tr ',' '\n' | sed 's/^ *//' | grep '^dev\.github-pet\.' | sort > "$1.domains"
  ls -1 "$HOME/Library/Preferences" | grep '^dev\.github-pet\.' | sort > "$1.plists"
  if [[ -f $real_plist ]]; then shasum -a 256 "$real_plist" | cut -d' ' -f1 > "$1.realprefs"; else echo absent > "$1.realprefs"; fi
  defaults export dev.github-pet.GitHubPet - 2>/dev/null | shasum -a 256 | cut -d' ' -f1 >> "$1.realprefs"
}

descendants() {  # all descendant PIDs of $1
  local kids=($(pgrep -P "$1" 2>/dev/null))
  for k in $kids; do print $k; descendants $k; done
}

# Launch, monitor and quit one app process. $1 = run dir; remaining args = app arguments.
run_app() {
  local dir=$1; shift
  mkdir -p "$dir"
  rm -f "$tripwire/invocations.log"
  snapshot "$dir/before"
  local saved_pids=$(pgrep -f '/github-pet-builds/' | sort | tr '\n' ' ')
  print -r -- "${(q)binary} ${(q)@}" > "$dir/argv.txt"
  PATH="$tripwire:$PATH" GITHUB_PET_GH_PATH="$tripwire/gh" "$binary" "$@" > "$dir/stdout.log" 2> "$dir/stderr.log" &
  local pid=$! started=$SECONDS quit_sent=0 code
  print $pid > "$dir/pid"
  : > "$dir/monitor.log"
  local deadline=$limit; [[ $mode == isolation ]] && deadline=$idle
  while kill -0 $pid 2>/dev/null; do
    local kids=($(descendants $pid))
    (( ${#kids} )) && print "$((SECONDS - started))s children: $(ps -o pid=,comm= -p ${(j:,:)kids} 2>/dev/null | tr '\n' ';')" >> "$dir/monitor.log"
    local net=$(lsof -nP -a -p $pid -i 2>/dev/null | tail -n +2)
    [[ -n $net ]] && print "$((SECONDS - started))s sockets: $net" >> "$dir/monitor.log"
    for k in $kids; do
      net=$(lsof -nP -a -p $k -i 2>/dev/null | tail -n +2)
      [[ -n $net ]] && print "$((SECONDS - started))s child $k sockets: $net" >> "$dir/monitor.log"
    done
    if (( ! quit_sent && SECONDS - started >= deadline )); then
      "$quitter" $pid; print "$((SECONDS - started))s normal quit requested (rc $?)" >> "$dir/monitor.log"; quit_sent=1
    fi
    if (( quit_sent && SECONDS - started >= deadline + 15 )); then
      print "$((SECONDS - started))s did not exit after quit; SIGKILL" >> "$dir/monitor.log"; kill -9 $pid; break
    fi
    sleep 0.25
  done
  wait $pid; code=$?
  print $code > "$dir/exit-code"
  sleep 1  # let cfprefsd settle the removed domain
  snapshot "$dir/after"
  [[ -f $tripwire/invocations.log ]] && cp "$tripwire/invocations.log" "$dir/gh-invocations.log"

  note ""; note "### ${dir:t}"; note ""
  note "argv: \`$(cat "$dir/argv.txt")\`; exit $code; quit requested by QA: $quit_sent."
  grep -q 'SIGKILL' "$dir/monitor.log" && fail "app ignored the normal quit and was killed"
  [[ -s $dir/gh-invocations.log ]] && fail "gh was executed: $(head -3 "$dir/gh-invocations.log")" || pass "tripwire gh never executed"
  grep -q 'children:' "$dir/monitor.log" && fail "child processes observed (see monitor.log)" || pass "no child processes observed (250 ms polling)"
  grep -q 'sockets:' "$dir/monitor.log" && fail "network sockets observed (see monitor.log)" || pass "no network sockets observed (250 ms polling)"
  diff -q "$dir/before.realprefs" "$dir/after.realprefs" >/dev/null && pass "real preferences unchanged" \
    || fail "real preferences changed during the run (the saved app also writes them; attribute by hand)"
  local added=$(comm -13 "$dir/before.domains" "$dir/after.domains"; comm -13 "$dir/before.plists" "$dir/after.plists")
  local removed=$(comm -23 "$dir/before.domains" "$dir/after.domains"; comm -23 "$dir/before.plists" "$dir/after.plists")
  [[ -z $added ]] && pass "no preference domain left behind" || fail "left behind: $(print -r -- $added | tr '\n' ' ')"
  [[ -z $removed ]] && pass "no pre-existing domain removed" || fail "pre-existing domain removed: $(print -r -- $removed | tr '\n' ' ')"
  local saved_after=$(pgrep -f '/github-pet-builds/' | sort | tr '\n' ' ')
  [[ $saved_pids == $saved_after ]] && pass "saved build processes untouched ($saved_after)" || fail "saved build processes changed: [$saved_pids] -> [$saved_after]"
}

# 5. Output structure: each step needs a JSON+PNG pair, all JSON must parse, and when
# privacy is on, no invented account/target name may appear in the scope header.
check_output() {  # $1 = scenario output dir
  python3 -I - "$1" "${QA_PRIVACY_NAMES:-}" <<'PY' | tee -a "$summary"
import json, pathlib, re, sys
out, extra = pathlib.Path(sys.argv[1]), sys.argv[2]
files = [p for p in out.rglob("*") if p.is_file()]
jsons = {p.with_suffix(""): p for p in files if p.suffix == ".json"}
pngs = {p.with_suffix(""): p for p in files if p.suffix == ".png"}
bad = []
if not jsons: bad.append("no JSON written")
for stem in sorted(set(jsons) ^ set(pngs)):
    bad.append(f"unpaired step {stem.relative_to(out)}")
for stem in pngs:
    if pngs[stem].read_bytes()[:8] != b"\x89PNG\r\n\x1a\n": bad.append(f"not a PNG: {pngs[stem].name}")
names = re.compile(r"demo-(a|b|outside)|demo-[a-z]+/pet" + (("|" + extra) if extra else ""), re.I)
for stem, path in sorted(jsons.items()):
    try: data = json.loads(path.read_text())
    except Exception as e: bad.append(f"invalid JSON {path.name}: {e}"); continue
    text = json.dumps(data)
    if re.search(r'"privacy[^"]*"\s*:\s*true', text, re.I):
        for key in ("scopeHeader", "scopeSummary", "header", "summary"):
            for m in re.finditer(r'"%s"\s*:\s*"([^"]*)"' % key, text):
                if names.search(m.group(1)): bad.append(f"name in {key} with privacy on: {path.name}: {m.group(1)!r}")
print(f"- structure: {len(jsons)} JSON, {len(pngs)} PNG")
for b in bad: print(f"- FAIL: {b}")
if not bad: print("- ok: every step has a parseable JSON+PNG pair; no privacy-on header name leak by key grep")
sys.exit(1 if bad else 0)
PY
  (( $? )) && failures=$((failures + 1))
}

if (( $# == 0 )); then
  mode=isolation
  run_app "$evidence/${QA_LABEL:-isolation-baseline}" "$sim_flag"
else
  mode=scenario
  for scenario in "$@"; do
    label=${${scenario:t}%.json}
    out=$evidence/$label
    [[ -e $out/output ]] && { fail "$out/output already exists; refusing to mix runs"; continue; }
    arg=$scenario; [[ -f $scenario ]] && arg=$(cat "$scenario")
    run_app "$out" "$sim_flag" "$scenario_flag" "$arg" "$output_flag" "$out/output"
    [[ $(cat "$out/exit-code") == 0 ]] || fail "scenario exit code $(cat "$out/exit-code")"
    check_output "$out/output"
  done
fi

note ""
note "Finished $(date -u +%FT%TZ): $failures mechanical failure(s). Product correctness is not judged here."
exit $(( failures > 0 ))
