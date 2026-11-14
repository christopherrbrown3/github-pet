#!/bin/zsh
# Focused packaging regressions: reject shallow history and unsuccessful Intel smoke children.
# No app compilation, network access, credentials or changes to the caller's checkout.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/source/scripts" "$scratch/bin"
cp scripts/{build-app,package-zip}.sh "$scratch/source/scripts/"
cp VERSION "$scratch/source/"
git init -q "$scratch/source"
git -C "$scratch/source" add .
for number in 1 2 3; do
  git -C "$scratch/source" -c user.name=PackagingTest -c user.email=packaging@example.invalid \
    -c commit.gpgsign=false commit -qm "fixture $number" --allow-empty
done

# Exercise the real smoke script with a fake architecture launcher and app. These fixtures
# test exit/report handling only; they neither require nor claim actual Rosetta execution.
mkdir -p "$scratch/intel/scripts" "$scratch/intel/Test.app/Contents/MacOS"
cp scripts/intel-smoke.sh "$scratch/intel/scripts/"
cat > "$scratch/bin/lipo" <<'SH'
#!/bin/sh
echo x86_64
SH
cat > "$scratch/bin/arch" <<'SH'
#!/bin/sh
test "$1" = -x86_64 || exit 64
shift
exec "$@"
SH
cat > "$scratch/intel/Test.app/Contents/MacOS/GitHubPet" <<'SH'
#!/bin/sh
test "$1" = --render-snapshots || exit 64
mkdir -p "$2"
printf '%s\n' '## 01-baseline' 'state=Up to date badge=3 rows=3 demo=true' > "$2/report.txt"
exit "$SMOKE_TEST_EXIT"
SH
chmod +x "$scratch/bin/"{lipo,arch} "$scratch/intel/Test.app/Contents/MacOS/GitHubPet"
for child_code in 0 86; do
  log=$scratch/intel-$child_code.log
  if PATH="$scratch/bin:$PATH" SMOKE_TEST_EXIT=$child_code \
    "$scratch/intel/scripts/intel-smoke.sh" Test.app >"$log" 2>&1; then
    result=0
  else
    result=$?
  fi
  test -f "$scratch/intel/.build/intel-smoke/report.txt"
  if [[ $result != $child_code ]]; then
    cat "$log" >&2
    echo "FAIL intel-smoke child=$child_code: expected exit $child_code, got $result" >&2
    exit 1
  fi
  if (( child_code == 0 )); then
    grep -q 'x86_64 slice ran the snapshot scenario' "$log"
  else
    grep -q 'exited unsuccessfully (86)' "$log"
    if grep -q 'x86_64 slice ran the snapshot scenario' "$log"; then
      echo 'FAIL unsuccessful Intel child reported success' >&2
      exit 1
    fi
  fi
  echo "PASS intel-smoke child=$child_code with usable report (exit $result)"
done

# Reaching this sentinel proves the complete checkout passed the provenance guard. Never compile.
cat > "$scratch/bin/swift" <<'SH'
#!/bin/sh
echo 'packaging-test: compiler reached' >&2
exit 86
SH
chmod +x "$scratch/bin/swift"

for depth in full 1 2; do
  clone=$scratch/clone-$depth
  if [[ $depth == full ]]; then
    git clone -q --no-local "$scratch/source" "$clone"
    expected_code=86
    test "$(git -C "$clone" rev-list --count HEAD)" -eq 3
  else
    git clone -q --depth "$depth" "file://$scratch/source" "$clone"
    expected_code=65
    test "$(git -C "$clone" rev-list --count HEAD)" -eq "$depth"
    test "$(git -C "$clone" rev-parse --is-shallow-repository)" = true
  fi
  for script in build-app package-zip; do
    log=$scratch/$depth-$script.log
    if PATH="$scratch/bin:$PATH" "$clone/scripts/$script.sh" >"$log" 2>&1; then
      result=0
    else
      result=$?
    fi
    if [[ $result != $expected_code ]]; then
      cat "$log" >&2
      echo "FAIL $script depth=$depth: expected exit $expected_code, got $result" >&2
      exit 1
    fi
    if [[ $depth == full ]]; then
      grep -q 'packaging-test: compiler reached' "$log"
    else
      grep -q 'requires a Git checkout with complete history' "$log"
      if grep -q 'packaging-test: compiler reached' "$log"; then
        echo "FAIL $script depth=$depth invoked Swift" >&2
        exit 1
      fi
      test ! -d "$clone/.build"
    fi
    echo "PASS $script depth=$depth (exit $result)"
  done
done
