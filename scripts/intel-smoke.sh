#!/bin/zsh
# Smoke-test the already packaged x86_64 app under Rosetta using one offline startup and quit.
# Usage: scripts/intel-smoke.sh [path/to/GitHubPet.app]
set -euo pipefail
cd "${0:A:h}/.."

exec python3 - "${1:-.build/app/GitHubPet.app}" <<'PY'
import json
import os
import plistlib
import re
import resource
import subprocess
import sys
import tempfile
from pathlib import Path

evidence = Path(".build/intel-smoke").resolve()
evidence.mkdir(parents=True, exist_ok=True)
run = Path(tempfile.mkdtemp(prefix="run-", dir=evidence))
ledger = run / "steps.tsv"


def record(step, detail):
    line = f"{step}\t{detail}"
    print(f"intel-smoke: {line}", flush=True)
    with ledger.open("a") as log:
        print(line, file=log)


def fail(detail, code=1):
    record("FAIL", detail)
    sys.exit(code)


def check(condition, detail):
    if not condition:
        raise ValueError(detail)


app = Path(sys.argv[1]).resolve()
binary = app / "Contents/MacOS/GitHubPet"
expected = os.environ.get("EXPECTED_SOURCE_SHA")
if expected:
    if not re.fullmatch(r"[0-9a-f]{40}", expected):
        fail("invalid expected source revision")
    record("expected-revision", expected)
try:
    with (app / "Contents/Info.plist").open("rb") as plist:
        bundle = plistlib.load(plist)
    check(isinstance(bundle, dict), "invalid bundle plist")
    revision = bundle.get("GitHubPetSourceRevision")
    check(isinstance(revision, str) and re.fullmatch(r"[0-9a-f]{40}", revision), "invalid bundle revision")
    record("bundle-revision", revision)
    check(not expected or revision == expected, "bundle revision differs from expected source")
    archs = subprocess.run(["lipo", "-archs", str(binary)], check=True,
                           capture_output=True, text=True, timeout=10).stdout.split()
    check({"arm64", "x86_64"}.issubset(archs) and os.access(binary, os.X_OK), "unusable universal executable")
    record("bundle", "arm64 and x86_64")
except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
    fail(f"bundle verification failed: {error}")

try:
    probe = subprocess.run(["arch", "-x86_64", "/usr/sbin/sysctl", "-n", "sysctl.proc_translated"],
                           capture_output=True, text=True, env={**os.environ, "LC_ALL": "C"}, timeout=15)
except (OSError, subprocess.SubprocessError) as error:
    fail(f"translation probe failed: {error}")
if probe.returncode:
    if "Bad CPU type in executable" in probe.stderr:
        record("SKIP", "Rosetta is unavailable; the x86_64 slice was not run")
        sys.exit(0)
    fail(f"translation probe exited {probe.returncode}: {probe.stderr.strip()}")
if probe.stdout.strip() != "1":
    fail("x86_64 probe did not report translation")
record("translation", "sysctl.proc_translated=1")

scenario = run / "startup.json"
scenario.write_text(json.dumps({"name": "intel-startup", "steps": [{"action": "quit"}]}))
output = run / "app"
tripwire_dir = run / "tripwire"
tripwire_dir.mkdir()
tripwire = tripwire_dir / "gh"
tripwire.write_text('#!/bin/sh\nprintf "%s\\n" "gh called" > "$GITHUB_PET_INTEL_GH_LOG"\nexit 99\n')
tripwire.chmod(0o700)
gh_log = run / "gh-called"
env = {**os.environ, "PATH": str(tripwire_dir) + os.pathsep + os.environ.get("PATH", os.defpath),
       "GITHUB_PET_GH_PATH": str(tripwire), "GITHUB_PET_INTEL_GH_LOG": str(gh_log)}
# Exercise the bundled pack even if the calling shell has a development override.
env.pop("GITHUB_PET_PACK_DIR", None)


def bound_child_files():
    # The scenario produces two small screenshots and two JSON records.
    maximum = 4 * 1024 * 1024
    _, hard_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    if hard_limit != resource.RLIM_INFINITY:
        maximum = min(maximum, hard_limit)
    resource.setrlimit(resource.RLIMIT_FSIZE, (maximum, hard_limit))


record("launch", "x86_64 offline startup and quit")
try:
    with (run / "app.log").open("wb") as console:
        child = subprocess.run(["arch", "-x86_64", str(binary), "--simulate-monitoring-scope",
                                "--qa-scenario", str(scenario), "--qa-output", str(output)],
                               stdout=console, stderr=subprocess.STDOUT, env=env,
                               preexec_fn=bound_child_files, timeout=45)
except subprocess.TimeoutExpired:
    # subprocess.run kills and reaps this child before raising.
    fail("x86_64 startup timed out after 45 seconds", 124)
except (OSError, subprocess.SubprocessError) as error:
    fail(f"x86_64 startup could not run: {error}")
record("child-exit", child.returncode)
if child.returncode:
    code = child.returncode if child.returncode > 0 else 128 - child.returncode
    fail(f"x86_64 slice exited unsuccessfully ({code})", code)

try:
    check(not gh_log.exists(), "GitHub CLI tripwire fired")
    record("no-gh", "tripwire clear")
    start = json.loads((output / "step-00-launch.json").read_text())
    inbox = start["inbox"]
    scope = start["monitoringScope"]
    rows = inbox["rows"]
    check(start["step"] == 0 and start["action"] == "launch" and inbox["status"] == "Up to date"
          and inbox["demoLabel"] is True and inbox["simulatedLabel"] is True
          and scope["identity"] == "github:A" and scope["active"] == "Selected"
          and isinstance(rows, list) and rows and all(row["isDemo"] is True for row in rows),
          "unusable offline startup record")
    record("startup", f"ready with {len(rows)} Demo rows")
    summary = json.loads((output / "runner.json").read_text())
    quit = summary["quit"]
    domain = start["defaultsDomain"]
    check(summary["scenario"] == "intel-startup" and summary["completed"] is True and summary["steps"] == 1
          and isinstance(domain, str) and domain.startswith("dev.github-pet.scope-simulation.")
          and summary["defaultsDomain"] == domain and quit["domainKeysAfterCleanup"] == 0
          and quit["heldAtQuit"] == 0 and quit["plistOnDisk"] is False, "offline runner did not cleanly quit")
    record("quit", "simulated defaults cleared and no plist")
    png = output / "step-00-launch-inbox.png"
    with png.open("rb") as image:
        check(image.read(8) == b"\x89PNG\r\n\x1a\n", "startup Inbox is not PNG")
    with tempfile.TemporaryDirectory() as scratch:
        decoded = Path(scratch) / "inbox.bmp"
        subprocess.run(["sips", "-s", "format", "bmp", str(png), "--out", str(decoded)],
                       check=True, capture_output=True, timeout=10)
        check(decoded.stat().st_size > 54, "startup Inbox PNG contains no decoded pixels")
    record("image", "startup Inbox PNG decoded")
except (OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
    fail(f"unusable translated startup evidence: {error}")

record("PASS", "x86_64 slice started and quit under Rosetta")
PY
