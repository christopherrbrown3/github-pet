"""One bounded Herdr event wait, then inspect the green CI artifact. No CI polling."""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "docs/qa/pr43-f1cfada"
with (out / "ci-event-wait.log").open("w") as log:
    result = subprocess.run(["hc", "wait", "t24", "--timeout", "900"], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=910)
    log.write(result.stdout)
    state = json.loads(result.stdout)
    if not state.get("ended") or state.get("exit_code") != 0:
        print("CI watcher did not complete successfully; artifact acceptance pending")
        sys.exit(1)
result = subprocess.run([sys.executable, str(root / "scripts/qa/pr43-artifact.py"),
                         "f1cfada8aeb28588e86952d39496f0cfeee03c34", "43606856503"], timeout=240)
sys.exit(result.returncode)
