"""PR53 (#52) functional QA on the saved exact-head app: gh setup links.

    python3 -I scripts/qa/pr53-gh-setup.py <work-dir>

A. --render-snapshots with a logging fake gh first on PATH and as GITHUB_PET_GH_PATH: the
   setup scenarios must never launch gh, must leave no preferences file, and must write the
   eight gh-setup PNGs plus report lines. QA views the PNGs by hand.
B. Short live launches (--gh, throwaway --defaults-suite, --reset-settings) with a missing,
   a non-executable and a signed-out fake gh, then a normal quit by PID. Records which gh
   commands the real client ran and the app's stderr. Visible state needs GUI (limit).
"""
import hashlib, json, os, pathlib, shutil, subprocess, sys, time, uuid

sha = "09b260a38efdec0c9606f3977675dc6d85c847c4"
work = pathlib.Path(sys.argv[1]); work.mkdir(parents=True, exist_ok=True)
qa_root = pathlib.Path(__file__).resolve().parents[2]
out = qa_root / f"docs/qa/pr53-{sha[:7]}"; out.mkdir(parents=True, exist_ok=True)
app = pathlib.Path(f"/Users/chris/github-pet-builds/pr53-{sha[:7]}/GitHubPet.app")
binary = app / "Contents/MacOS/GitHubPet"
prefs = pathlib.Path.home() / "Library/Preferences"
real = prefs / "dev.github-pet.GitHubPet.plist"
log, failures = [], 0

def note(s): log.append(s); print(s)
def check(ok, what):
    global failures
    failures += not ok
    note(("- ok: " if ok else "- FAIL: ") + what)
def real_hash(): return hashlib.sha256(real.read_bytes()).hexdigest() if real.exists() else "absent"
def saved_pids(): return sorted(subprocess.run(["pgrep", "-f", "/github-pet-builds/b0127f0/"], capture_output=True, text=True).stdout.split())
def other_apps():
    ps = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True, text=True).stdout
    return [l for l in ps.splitlines() if l.rstrip().endswith("/Contents/MacOS/GitHubPet") and "/github-pet-builds/b0127f0/" not in l]

revision = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :GitHubPetSourceRevision", str(app / "Contents/Info.plist")],
                          capture_output=True, text=True).stdout.strip()
assert revision == sha, revision
assert not other_apps(), f"another QA app is running: {other_apps()}"
quitter = work / "quit-pid"
if not quitter.exists():
    subprocess.run(["swiftc", "-O", "-o", str(quitter), str(qa_root / "scripts/qa/quit-pid.swift")], check=True)

def fake(dir, body, executable=True):
    dir.mkdir(parents=True, exist_ok=True)
    gh = dir / "gh"
    gh.write_text("#!/bin/sh\necho \"$*\" >> \"" + str(dir / "invocations.log") + "\"\n" + body)
    gh.chmod(0o755 if executable else 0o644)
    (dir / "invocations.log").unlink(missing_ok=True)
    return gh

def invocations(dir):
    f = dir / "invocations.log"
    return f.read_text().splitlines() if f.exists() else []

note(f"# PR53 functional QA, saved app {app}, revision {revision}")
note(f"binary sha256 {hashlib.sha256(binary.read_bytes()).hexdigest()}")
real_before, saved_before = real_hash(), saved_pids()

# A. Render mode.
note("\n## A. --render-snapshots, logging fake gh on PATH and as GITHUB_PET_GH_PATH")
trap_dir = work / "trap"
trap = fake(trap_dir, "exit 1\n")
render = work / "render"; shutil.rmtree(render, ignore_errors=True)
before_files = set(p.name for p in prefs.glob("dev.github-pet.*"))
p = subprocess.Popen([str(binary), "--render-snapshots", str(render)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     env={"HOME": str(pathlib.Path.home()), "PATH": f"{trap_dir}:/usr/bin:/bin", "GITHUB_PET_GH_PATH": str(trap)})
stdout, stderr = p.communicate(timeout=400)
(out / "render-stderr.log").write_bytes(stderr)
check(p.returncode == 0, f"render exit {p.returncode}")
check(invocations(trap_dir) == [], f"gh invocations during render: {invocations(trap_dir)}")
time.sleep(20)
own = f"dev.github-pet.render-snapshots.{p.pid}.plist"
new_files = set(p2.name for p2 in prefs.glob("dev.github-pet.*")) - before_files
check(own not in new_files, f"no {own} 20 s after exit (other agents' new files ignored: {sorted(new_files - {own})})")
report = (render / "report.txt").read_text()
setup_lines = [l for l in report.splitlines() if l.startswith("setup=")]
(out / "render-report-setup.txt").write_text(report[report.index("## gh setup links"):] if "## gh setup links" in report else "missing section\n")
for l in setup_lines: note("  " + l)
check(len(setup_lines) == 2, "two setup report lines")
for name, link in [("ghmissing", "Get GitHub CLI"), ("unauthenticated", "How to sign in")]:
    line = next((l for l in setup_lines if l.startswith(f"setup={name} ")), "")
    check("source=githubCLI" in line and "demo=false" in line and "rows=0" in line and "unseen=0" in line
          and "clip=none" in line and f'["{link}"]' in line, f"{name}: real CLI source, no rows/unseen/clip, link {link!r}")
pngs = sorted(render.glob("gh-setup-*.png"))
check(len(pngs) == 8, f"{len(pngs)} gh-setup PNGs")
for png in pngs: shutil.copy(png, out / png.name)
if (render / "11-gh-override-inbox.png").exists(): shutil.copy(render / "11-gh-override-inbox.png", out)

# B. Live launches with the real client and fake gh variants.
cases = [
    ("missing", None),
    ("non-executable", dict(body="exit 0\n", executable=False)),
    ("signed-out", dict(body='echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2\n'
                            'case "$1" in auth) exit 1;; *) exit 4;; esac\n')),
]
for name, spec in cases:
    note(f"\n## B. live --gh launch, {name} gh")
    d = work / f"gh-{name}"
    shutil.rmtree(d, ignore_errors=True); d.mkdir(parents=True)
    gh = d / "gh" if spec is None else fake(d, spec["body"], spec.get("executable", True))
    path_trap = fake(work / f"path-{name}", "exit 1\n")  # a real gh found via PATH would be a bug
    suite = f"dev.github-pet.qa.pr53.{uuid.uuid4()}"
    p = subprocess.Popen([str(binary), "--defaults-suite", suite, "--reset-settings", "--gh"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env={"HOME": str(pathlib.Path.home()), "PATH": f"{path_trap.parent}:/usr/bin:/bin", "GITHUB_PET_GH_PATH": str(gh)})
    time.sleep(10)
    sockets = subprocess.run(["lsof", "-nP", "-a", "-p", str(p.pid), "-i"], capture_output=True, text=True).stdout
    alive = p.poll() is None
    subprocess.run([str(quitter), str(p.pid)])
    try: _, stderr = p.communicate(timeout=20); quit_ok = True
    except subprocess.TimeoutExpired: p.kill(); _, stderr = p.communicate(); quit_ok = False
    (out / f"live-{name}-stderr.log").write_bytes(stderr)
    (out / f"live-{name}-sockets.txt").write_text(sockets)
    subprocess.run(["defaults", "delete", suite], capture_output=True)
    (prefs / f"{suite}.plist").unlink(missing_ok=True)
    calls = invocations(d)
    check(alive and quit_ok and p.returncode == 0, f"stayed up 10 s, quit normally (exit {p.returncode})")
    check(invocations(path_trap.parent) == [], "no gh from PATH used despite the override")
    if name == "signed-out":
        check(bool(calls) and all(c.startswith("auth status") for c in calls), f"only auth status run: {calls}")
    else:
        check(calls == [], f"fake gh never executed: {calls}")
    note(f"  stderr: {stderr.decode(errors='replace').strip()[:300]}")
    note(f"  sockets at 10 s (public status client expected; no gh): {len(sockets.splitlines()) - 1 if sockets else 0}")

check(real_hash() == real_before, "real preferences unchanged")
check(saved_pids() == saved_before, f"saved b0127f0 process untouched {saved_pids()}")
note(f"\nmechanical failures: {failures}; PNG content judged by hand")
(out / "functional.md").write_text("\n".join(log) + "\n")
sys.exit(1 if failures else 0)
