import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "docs/qa/pr47-bb44d7b"
out.mkdir(exist_ok=True)
repo = "christopherrbrown3/github-pet"
run_id = "43633750212"
def run(argv):
    return subprocess.check_output(argv, text=True, stderr=subprocess.STDOUT, timeout=90)
state = json.loads(run(["gh", "run", "view", run_id, "--repo", repo, "--json", "headSha,status,conclusion"]))
assert state["headSha"] == "bb44d7b47c300793b7a9ab30c73a9844b5f16f82" and state["conclusion"] == "success"
download = out / "download"
download.mkdir()
run(["gh", "run", "download", run_id, "--repo", repo, "--name", "render-check", "--dir", str(download)])
report = (download / "report.txt").read_text()
(out / "render-report.txt").write_text(report)
ci = run(["gh", "run", "view", run_id, "--repo", repo, "--log"])
(out / "ci.log").write_text(ci)
assert "render-check: all checks passed" in ci
def section(name):
    return report.split("## " + name + "\n", 1)[1].split("\n## ", 1)[0]
assert "rows=4 demo=true mood=attention" in section("02-injected")
assert "rows=4 demo=true mood=attention" in section("03-replayed")
assert "unseen-incidents=1" in section("10c-incident-major")
assert "unseen-incidents=2" in section("10e-incident-critical")
summary = [json.dumps(state), "PASS actual CI deliberate fixture injection/replay/incident scenarios",
    "PASS actual CI full render-check; normal-load artifact does not simulate a >staleAfter render gap"]
summary += [line for line in ci.splitlines() if re.search(r"Test run with|SKIP live gesture|render-check: all", line)]
(out / "ci-artifact.log").write_text("\n".join(summary) + "\n")
print("PR47 actual CI artifact focused checks PASS")
