"""Bounded Herdr event wait and focused checks of actual PR42 render evidence."""
import json
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "docs/qa/pr42-0f72096"
repo = "christopherrbrown3/github-pet"
sha = "0f720962d549185c0a04d928c2952ef7e9bc3da0"
run_id = "43607798711"
with (out / "ci-artifact.log").open("w") as log:
    def run(argv, timeout=60):
        p = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        assert p.returncode == 0, p.stdout
        return p.stdout
    state = json.loads(run(["hc", "wait", "t2g", "--timeout", "900"], timeout=910))
    log.write(json.dumps(state) + "\n")
    assert state.get("ended") and state.get("exit_code") == 0, state
    ci = json.loads(run(["gh", "run", "view", run_id, "--repo", repo, "--json", "headSha,status,conclusion,event"]))
    assert ci["headSha"] == sha and ci["conclusion"] == "success"
    log.write(json.dumps(ci) + "\n")
    download = out / "download"
    download.mkdir()
    run(["gh", "run", "download", run_id, "--repo", repo, "--name", "render-check", "--dir", str(download)])
    report = (download / "report.txt").read_text()
    (out / "render-report.txt").write_text(report)
    for case in ["transparent", "no-candidate"]:
        assert f"hover failure {case}: meets-target=false infinite-gap=true report-completed=true" in report
        log.write("PASS actual CI diagnostic " + case + "\n")
    for case in ["dropped past edge", "dropped past saved edge", "dropped beyond all displays"]:
        line = next(line for line in report.splitlines() if line.startswith(case + ":"))
        assert "panel-inside=true saved-equals-shown=true expected-origin=true" in line
        if case == "dropped past saved edge":
            assert "saved-before-equals-settled=true" in line
        log.write("PASS " + line + "\n")
    hover = [line for line in report.splitlines() if re.match(r"hover [a-z]+-[0-9]+-", line)]
    assert len(hover) == 11, len(hover)
    for line in hover:
        assert "overlap=0 lane=clear on-screen=true meets-target=true" in line, line
        assert float(re.search(r"arrow-anchor-to-static-art=([\d.]+)", line)[1]) <= 12
    log.write("PASS actual CI 11 measured hover cases\n")
    assert "hover growth: grew=true before-side=right after-side=left art-clear=true labels-clear=true on-screen=true" in report
    log.write("PASS content growth repositions\n")
    ci_log = run(["gh", "run", "view", run_id, "--repo", repo, "--log"], timeout=90)
    (out / "ci.log").write_text(ci_log)
    log.write("PASS green exact-head CI/render evidence downloaded and checked\n")
print("PR42 actual green CI/render focused checks PASS")
