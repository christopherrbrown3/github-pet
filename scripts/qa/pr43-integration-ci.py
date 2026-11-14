"""One event wait, actual universal ZIP checks, then integrated render-report checks."""
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "docs/qa/pr43-561fafc"
sha = "561fafc6705b4e587aa23327fc029f965edac33a"
run_id = "43608764228"
repo = "christopherrbrown3/github-pet"
with (out / "integration-ci.log").open("w") as log:
    state = subprocess.run(["hc", "wait", "t2j", "--timeout", "900"], text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=910)
    log.write(state.stdout)
    result = json.loads(state.stdout)
    assert result.get("ended") and result.get("exit_code") == 0, result
    artifact = subprocess.run([sys.executable, str(root / "scripts/qa/pr43-artifact.py"), sha, run_id], timeout=240)
    assert artifact.returncode == 0
    render = out / "render-download"
    render.mkdir()
    subprocess.run(["gh", "run", "download", run_id, "--repo", repo, "--name", "render-check", "--dir", str(render)], check=True, timeout=90)
    report = (render / "report.txt").read_text()
    (out / "render-report.txt").write_text(report)
    required = [
        "hover failure transparent: meets-target=false infinite-gap=true report-completed=true",
        "hover failure no-candidate: meets-target=false infinite-gap=true report-completed=true",
        "dropped past saved edge: panel-inside=true saved-equals-shown=true expected-origin=true saved-before-equals-settled=true",
        "dropped beyond all displays: panel-inside=true saved-equals-shown=true expected-origin=true",
        "hover growth: grew=true before-side=right after-side=left art-clear=true labels-clear=true on-screen=true",
        "incident-marker=minor ", "incident-marker=major ", "incident-marker=critical ",
        "service=GitHub status unavailable: simulated status fetch failure",
        "service=No active GitHub incidents incident-rows=0 unseen-incidents=0",
    ]
    for text in required:
        assert text in report, text
        log.write("PASS packaged-binary render report: " + text + "\n")
    log.write("PASS integrated incidents/hover behavior in actual CI packaged binary\n")
print("PR43 integrated actual green ZIP + render evidence PASS")
