#!/bin/zsh
# PR49 runner trust checks against the built app: refusals (R1), invalid scenarios (R2),
# output-directory safety (R3) and determinism (R5). R4 (PNG/JSON agreement) is judged by
# viewing PNGs. Every probe path lives under a private scratch root; nothing here writes
# outside it except the refused-path probes, which must write nothing.
#
#   scripts/qa/pr49-runner-trust.sh <app-binary> <private-scratch-root> <evidence-dir>
set -uo pipefail
binary=$1 root=$2 evidence=$3
mkdir -p "$root" "$evidence"
log=$evidence/runner-trust.md
failures=0
note() { print -r -- "$*" | tee -a "$log"; }
ok() { note "- ok: $*"; }
bad() { failures=$((failures + 1)); note "- FAIL: $*"; }

# Launch with a 120 s bound; returns the exit code (124 if it had to be killed).
launch() {
  "$binary" "$@" > "$root/last.out" 2> "$root/last.err" &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null && (( t < 480 )); do sleep 0.25; t=$((t + 1)); done
  if kill -0 $pid 2>/dev/null; then kill -9 $pid; wait $pid 2>/dev/null; return 124; fi
  wait $pid
}
expect_refused() {  # $1 description, $2 path that must stay absent or unchanged, then launch args
  local what=$1 watch=$2; shift 2
  local before=$(ls -la "$watch" 2>/dev/null | shasum | cut -c1-12)
  launch "$@"; local code=$?
  local after=$(ls -la "$watch" 2>/dev/null | shasum | cut -c1-12)
  local err=$(tr '\n' ' ' < "$root/last.err" | cut -c1-220)
  if (( code != 0 && code != 124 )) && [[ $before == $after ]]; then ok "$what: exit $code, nothing written ($err)"
  else bad "$what: exit $code, listing changed: $([[ $before != $after ]] && echo yes || echo no) ($err)"; fi
}

note "# PR49 runner trust checks"
note ""
note "binary $binary sha256 $(shasum -a 256 "$binary" | cut -d' ' -f1)"
note ""
note "## R1 opt-in refusals"
expect_refused "scenario without --simulate-monitoring-scope" "$root/r1a" --qa-scenario restore-before-display --qa-output "$root/r1a"
[[ -e $root/r1a ]] && bad "r1a output dir was created" || ok "r1a output dir never created"
expect_refused "scenario with --render-snapshots" "$root/r1b" --simulate-monitoring-scope --render-snapshots "$root/r1b-snap" \
  --qa-scenario restore-before-display --qa-output "$root/r1b"
[[ -e $root/r1b || -e $root/r1b-snap ]] && bad "r1b wrote output or snapshots" || ok "r1b nothing created"
expect_refused "--qa-output without --qa-scenario" "$root/r1c" --simulate-monitoring-scope --qa-output "$root/r1c"

note ""
note "## R2 invalid scenarios (exit 2, nothing written)"
inv=$root/invalid; mkdir -p "$inv"
print -r -- '{"name":"x","steps":[{"action":"refresh","label":"a"}' > "$inv/malformed.json"
print -r -- '{"name":"x","steps":[{"action":"explode","label":"a"}]}' > "$inv/unknown-action.json"
print -r -- '{"name":"x","steps":[{"action":"refresh","label":"a","bogus":1}]}' > "$inv/unknown-key.json"
print -r -- '{"name":"x","steps":[{"action":"refresh","label":"Bad_Label"}]}' > "$inv/bad-label.json"
print -r -- '{"name":"x","steps":[{"action":"quit","label":"q"},{"action":"refresh","label":"a"}]}' > "$inv/quit-not-last.json"
print -r -- '{"name":"x","steps":[{"action":"hold","count":9,"label":"a"}]}' > "$inv/hold-nine.json"
print -r -- '{"name":"x","steps":[{"action":"wait-real","seconds":61,"label":"a"}]}' > "$inv/wait-61.json"
print -r -- '{"name":"x","steps":[{"action":"partial","on":1,"label":"a"}]}' > "$inv/bool-as-number.json"
print -r -- '{"name":"x","steps":[{"action":"clock-advance","seconds":true,"label":"a"}]}' > "$inv/number-as-bool.json"
python3 -I -c 'import json,sys;print(json.dumps({"name":"x","steps":[{"action":"refresh","label":f"s{i}"} for i in range(100)]}))' > "$inv/hundred-steps.json"
for f in "$inv"/*.json; do
  expect_refused "invalid ${f:t}" "$root/r2-${f:t:r}" --simulate-monitoring-scope --qa-scenario "$f" --qa-output "$root/r2-${f:t:r}"
  [[ -n $(ls -A "$root/r2-${f:t:r}" 2>/dev/null) ]] && bad "${f:t} left files in its output dir"
done
expect_refused "unknown built-in name" "$root/r2-unknown-name" --simulate-monitoring-scope --qa-scenario no-such-scenario --qa-output "$root/r2-unknown-name"

note ""
note "## R3 output-directory safety"
victim=$root/victim.txt; print -r -- "victim original" > "$victim"; victim_hash=$(shasum "$victim" | cut -c1-12)
mkdir -p "$root/r3-foreign"; print -r -- keep > "$root/r3-foreign/notes.txt"
expect_refused "non-empty dir with a foreign file" "$root/r3-foreign" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$root/r3-foreign"
mkdir -p "$root/r3-hardlink"; print -r -- "GitHub Pet QA scenario runner output. Only runner files may live here." > "$root/r3-hardlink/.github-pet-qa-runner"
ln "$victim" "$root/r3-hardlink/step-01-x.json"
expect_refused "marker dir with a hard-linked step file" "$root/r3-hardlink" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$root/r3-hardlink"
mkdir -p "$root/r3-symlink"; cp "$root/r3-hardlink/.github-pet-qa-runner" "$root/r3-symlink/"
ln -s "$victim" "$root/r3-symlink/runner.json"
expect_refused "marker dir with a symlinked runner.json" "$root/r3-symlink" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$root/r3-symlink"
print -r -- "a file" > "$root/r3-file"
expect_refused "output path is a regular file" "$root/r3-file" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$root/r3-file"
expect_refused "output is the home directory" "$HOME" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$HOME"
expect_refused "output under /System" "/System/github-pet-qa-probe" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "/System/github-pet-qa-probe"
expect_refused "output inside the app bundle" "${binary:h:h}" --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "${binary:h:h}/qa-probe"
[[ -e ${binary:h:h}/qa-probe ]] && bad "qa-probe created inside the bundle"
[[ $(shasum "$victim" | cut -c1-12) == $victim_hash ]] && ok "victim file unchanged" || bad "victim file changed"
[[ -f $root/r3-foreign/notes.txt ]] && ok "foreign file kept" || bad "foreign file removed"

# A symlinked ancestor that exists before launch: resolved once, so output must land in the
# real directory and nowhere else.
mkdir -p "$root/r3-real"; ln -sfn "$root/r3-real" "$root/r3-link"
launch --simulate-monitoring-scope --qa-scenario restore-before-display --qa-output "$root/r3-link/out"; code=$?
note "- symlinked ancestor (pre-existing): exit $code; real dir files $(ls "$root/r3-real/out" 2>/dev/null | wc -l | tr -d ' '); link still a symlink: $([[ -L $root/r3-link ]] && echo yes || echo no)"
# Re-run into a runner-owned dir: old runner files are replaced, nothing else is touched.
launch --simulate-monitoring-scope --qa-scenario account-a-b-a --qa-output "$root/r3-real/out"; code=$?
remaining=$(ls "$root/r3-real/out" | grep -c 'reload-unknown-viewer')
(( code == 0 && remaining == 0 )) && ok "reuse of a runner dir replaced the old runner files (exit $code)" || bad "reuse: exit $code, stale files $remaining"
# Relative output resolves against the working directory.
(cd "$root" && launch --simulate-monitoring-scope --qa-scenario account-a-b-a --qa-output rel-out); code=$?
[[ $code == 0 && -f $root/rel-out/runner.json ]] && ok "relative output resolved under the working directory" || bad "relative output: exit $code"

note ""
note "## R5 determinism"
launch --simulate-monitoring-scope --qa-scenario stale-reply-after-apply --qa-output "$root/r5-one"; c1=$?
launch --simulate-monitoring-scope --qa-scenario stale-reply-after-apply --qa-output "$root/r5-two"; c2=$?
python3 -I - "$root/r5-one" "$root/r5-two" <<'PY' | tee -a "$log"
import json, pathlib, sys
a, b = map(pathlib.Path, sys.argv[1:3])
def norm(o):
    if isinstance(o, dict): return {k: norm(v) for k, v in o.items() if k not in ("defaultsDomain",)}
    if isinstance(o, list): return [norm(v) for v in o]
    return o
diffs = []
for f in sorted(a.glob("step-*.json")):
    if norm(json.loads(f.read_text())) != norm(json.loads((b / f.name).read_text())): diffs.append(f.name)
print("- " + ("FAIL: differing records " + ", ".join(diffs) if diffs else f"ok: {len(list(a.glob('step-*.json')))} step records identical apart from defaultsDomain"))
PY
(( c1 == 0 && c2 == 0 )) || bad "determinism runs exit $c1/$c2"
note ""
note "trust failures: $failures"
exit $(( failures > 0 ))
