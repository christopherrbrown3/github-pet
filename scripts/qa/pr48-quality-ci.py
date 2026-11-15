import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
sha, run_id, watcher = sys.argv[1:] if len(sys.argv) == 4 else ("1d5a9115d6ff338a308813cb01e1a2422824e606", "43737962079", "t3p")
out = root / ("docs/qa/pr48-" + sha[:7])
out.mkdir(parents=True, exist_ok=True)
with (out / "ci-event-wait.log").open("w") as log:
    p = subprocess.run(["hc", "wait", watcher, "--timeout", "900"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=910)
    log.write(p.stdout)
    state = json.loads(p.stdout)
    assert state.get("ended") and state.get("exit_code") == 0, state
p = subprocess.run([sys.executable, str(root / "scripts/qa/pr48-ci-evidence.py"), sha, run_id], timeout=240)
sys.exit(p.returncode)
