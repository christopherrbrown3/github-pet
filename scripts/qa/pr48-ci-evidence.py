import json
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
sha, run_id = sys.argv[1:] if len(sys.argv) == 3 else ("e2a11a559bfbfb791fcd68cd4aa37d77f1f4ce72", "43639314358")
out = root / ("docs/qa/pr48-" + sha[:7])
repo = "christopherrbrown3/github-pet"
def run(argv):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=90)
metadata = json.loads(run(["gh", "run", "view", run_id, "--repo", repo, "--json", "headSha,status,conclusion,event"]))
assert metadata["headSha"] == sha and metadata["conclusion"] == "success"
download = out / "download"
download.mkdir()
run(["gh", "run", "download", run_id, "--repo", repo, "--name", "render-check", "--dir", str(download)])
report = (download / "report.txt").read_text()
(out / "render-report.txt").write_text(report)
ci = run(["gh", "run", "view", run_id, "--repo", repo, "--log"])
(out / "ci.log").write_text(ci)
assert "render-check: all checks passed" in ci
summary = [json.dumps(metadata), "PASS actual current-head render artifact; fixtures do not test scoped live transport"]
summary += [line for line in ci.splitlines() if any(text in line for text in ["Test run with", "PASS external normal-import", "prelaunchCancellation", "inFlightCancellation", "SKIP live gesture", "render-check: all"]) ]
(out / "ci-summary.log").write_text("\n".join(summary) + "\n")
print("PR48 actual green CI/render evidence saved; independent legacy defect remains separate")
