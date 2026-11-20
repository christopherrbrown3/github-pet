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

# Exercise the real wrapper using a fake architecture launcher and app. These are evidence
# and exit-handling controls. Hosted CI runs the actual signed app separately.
mkdir -p "$scratch/intel/scripts" "$scratch/intel/Test.app/Contents/MacOS"
cp scripts/intel-smoke.sh "$scratch/intel/scripts/"
fixture_sha=0123456789abcdef0123456789abcdef01234567
python3 - "$scratch/intel/Test.app/Contents/Info.plist" "$fixture_sha" <<'PLIST'
import plistlib
import sys
with open(sys.argv[1], "wb") as out:
    plistlib.dump({"GitHubPetSourceRevision": sys.argv[2]}, out)
PLIST
cat > "$scratch/bin/lipo" <<'SH'
#!/bin/sh
echo 'x86_64 arm64'
SH
cat > "$scratch/bin/arch" <<'SH'
#!/bin/sh
test "$1" = -x86_64 || exit 64
shift
if [ "$1" = /usr/sbin/sysctl ]; then
  test "$2" = -n && test "$3" = sysctl.proc_translated || exit 64
  case "$SMOKE_CASE" in
    no-rosetta) echo 'arch: Bad CPU type in executable' >&2; exit 1 ;;
    probe-error) echo 'arch: permission denied' >&2; exit 1 ;;
    native) echo 0 ;;
    *) echo 1 ;;
  esac
  exit 0
fi
exec "$@"
SH
cat > "$scratch/intel/Test.app/Contents/MacOS/GitHubPet" <<'APP'
#!/usr/bin/env python3
import json
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

case = os.environ["SMOKE_CASE"]
Path(os.environ["SMOKE_SENTINEL"]).touch()
assert sys.argv[1:3] == ["--simulate-monitoring-scope", "--qa-scenario"]
assert sys.argv[4] == "--qa-output"
scenario = json.loads(Path(sys.argv[3]).read_text())
assert scenario == {"name": "intel-startup", "steps": [{"action": "quit"}]}
out = Path(sys.argv[5])
out.mkdir()
if case == "missing":
    sys.exit(0)
domain = "dev.github-pet.scope-simulation.packaging-test"
startup = {"step": 0, "action": "launch", "defaultsDomain": domain,
           "monitoringScope": {"identity": "github:A", "active": "Selected"},
           "inbox": {"status": "Up to date", "demoLabel": True, "simulatedLabel": True, "rows": [{"isDemo": True}]}}
(out / "step-00-launch.json").write_text("{" if case == "bad-json" else json.dumps(startup))
(out / "runner.json").write_text(json.dumps({"scenario": scenario["name"], "steps": 1,
    "defaultsDomain": domain, "completed": True, "quit": {
        "domainKeysAfterCleanup": int(case == "unclean"), "heldAtQuit": 0, "plistOnDisk": False}}))

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

signature = b"\x89PNG\r\n\x1a\n"
header = chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
pixels = chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff\x00\x00" * 2) * 2))
png = signature + header + pixels + chunk(b"IEND", b"")
(out / "step-00-launch-inbox.png").write_bytes(signature + header if case == "bad-png" else png)
if case == "gh":
    subprocess.run([os.environ["GITHUB_PET_GH_PATH"]], check=False)
sys.exit(86 if case == "nonzero" else 0)
APP
chmod +x "$scratch/bin/"{lipo,arch} "$scratch/intel/Test.app/Contents/MacOS/GitHubPet"
for smoke_case in normal nonzero missing bad-json bad-png unclean gh no-rosetta probe-error native wrong-revision; do
  log=$scratch/intel-$smoke_case.log
  sentinel=$scratch/launched-$smoke_case
  wanted_sha=$fixture_sha
  [[ $smoke_case != wrong-revision ]] || wanted_sha=0000000000000000000000000000000000000000
  case "$smoke_case" in
    normal) expected_code=0; expected_text='PASS.*x86_64 slice started and quit' ;;
    nonzero) expected_code=86; expected_text='exited unsuccessfully [(]86[)]' ;;
    missing|bad-json|bad-png) expected_code=1; expected_text='unusable translated startup evidence' ;;
    unclean) expected_code=1; expected_text='offline runner did not cleanly quit' ;;
    gh) expected_code=1; expected_text='GitHub CLI tripwire fired' ;;
    no-rosetta) expected_code=0; expected_text='SKIP.*Rosetta is unavailable' ;;
    probe-error) expected_code=1; expected_text='translation probe exited 1' ;;
    native) expected_code=1; expected_text='did not report translation' ;;
    wrong-revision) expected_code=1; expected_text='bundle revision differs from expected source' ;;
  esac
  if PATH="$scratch/bin:$PATH" SMOKE_CASE=$smoke_case SMOKE_SENTINEL=$sentinel EXPECTED_SOURCE_SHA=$wanted_sha \
    "$scratch/intel/scripts/intel-smoke.sh" Test.app >"$log" 2>&1; then
    result=0
  else
    result=$?
  fi
  if [[ $result != $expected_code ]] || ! grep -Eq "$expected_text" "$log"; then
    cat "$log" >&2
    echo "FAIL intel-smoke $smoke_case: expected exit $expected_code and '$expected_text', got $result" >&2
    exit 1
  fi
  case "$smoke_case" in
    no-rosetta|probe-error|native|wrong-revision) test ! -e "$sentinel" ;;
    *) test -e "$sentinel" ;;
  esac
  if [[ $smoke_case != normal ]] && grep -Eq 'PASS.*x86_64 slice started and quit' "$log"; then
    echo "FAIL intel-smoke $smoke_case reported runtime success" >&2
    exit 1
  fi
  echo "PASS intel-smoke $smoke_case (exit $result)"
done
test "$(find "$scratch/intel/.build/intel-smoke" -name steps.tsv | wc -l)" -eq 11

# The real built-ins stage only manifest-declared files. An unexpected asset fails verification.
python3 scripts/mascot-resources.py stage assets/mascots "$scratch/packs"
for pack in mona-pet-v1 little-chris-v1; do
  cmp "assets/mascots/$pack/manifest.json" "$scratch/packs/$pack/manifest.json"
  test ! -e "$scratch/packs/$pack/source"
done
touch "$scratch/packs/little-chris-v1/extra.png"
if python3 scripts/mascot-resources.py verify "$scratch/packs" >"$scratch/extra-assets.log" 2>&1; then
  echo 'FAIL mascot resources accepted an unexpected Little Chris asset' >&2
  exit 1
fi
grep -q 'bundled files differ from manifest runtime files' "$scratch/extra-assets.log"
echo 'PASS mascot resources stage the two manifests and runtime frames only'

# The icon verifier accepts a good bundle and rejects each way the icon can break.
icon_app=$scratch/icon/GitHubPet.app
mkdir -p "$icon_app/Contents/Resources"
iconutil -c icns assets/app-icon/AppIcon.iconset -o "$icon_app/Contents/Resources/AppIcon.icns"
write_icon_plist() {  # <CFBundleIconFile> <LSUIElement>
  python3 - "$icon_app/Contents/Info.plist" "$1" "$2" <<'PLIST'
import plistlib
import sys
info = {"LSUIElement": sys.argv[3] == "true"}
if sys.argv[2]:
    info["CFBundleIconFile"] = sys.argv[2]
with open(sys.argv[1], "wb") as out:
    plistlib.dump(info, out)
PLIST
}
write_icon_plist AppIcon true
scripts/verify-app-icon.sh "$icon_app" >/dev/null
for icon_case in missing-icns empty-icns garbage-icns wrong-name no-name dock-icon; do
  write_icon_plist AppIcon true
  case $icon_case in
    missing-icns) rm "$icon_app/Contents/Resources/AppIcon.icns"; wanted='missing or empty' ;;
    empty-icns) : > "$icon_app/Contents/Resources/AppIcon.icns"; wanted='missing or empty' ;;
    garbage-icns) printf 'icns-not-really' > "$icon_app/Contents/Resources/AppIcon.icns"; wanted='not a valid icns' ;;
    wrong-name) write_icon_plist Other true; wanted='CFBundleIconFile is not AppIcon' ;;
    no-name) write_icon_plist '' true; wanted='CFBundleIconFile is not AppIcon' ;;
    dock-icon) write_icon_plist AppIcon false; wanted='LSUIElement is not true' ;;
  esac
  if scripts/verify-app-icon.sh "$icon_app" >"$scratch/icon-$icon_case.log" 2>&1 || ! grep -q "$wanted" "$scratch/icon-$icon_case.log"; then
    cat "$scratch/icon-$icon_case.log" >&2
    echo "FAIL verify-app-icon $icon_case: expected failure '$wanted'" >&2
    exit 1
  fi
  echo "PASS verify-app-icon rejects $icon_case"
  iconutil -c icns assets/app-icon/AppIcon.iconset -o "$icon_app/Contents/Resources/AppIcon.icns"
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
