import hashlib
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[2]
held = root.parent / "developer-scope-core"
source = root.parent / "qa-verify-97e797a"
out = root / "docs/qa/pr48-97e797a"
out.mkdir(exist_ok=True)
sha = "97e797a32598dfd02624de35f19cb4af09fe209c"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=held, text=True).strip() == sha
assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=held, text=True).strip()
names = subprocess.check_output(["git", "diff", "--name-only", "1d5a911", "HEAD"], cwd=source, text=True).splitlines()
assert names == ["Tests/GitHubPetCoreTests/GitHubCLITests.swift"], names
previous = json.loads((root / "docs/qa/pr48-1d5a911/held-build-hashes.json").read_text())
current = {name: hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() for name in previous}
assert current == previous, "core build differs from accepted focused-quality build"
(out / "source-build-equality.json").write_text(json.dumps({"head": sha, "changed_files": names, "all_previous_core_objects_and_module_byte_identical": True, "hashes": current}, indent=2))
selected = "|".join(["legacyIncompleteAuthOrQueryCannotAcceptValidEmptyPayload", "legacyAggregatePreflightQueryBytesShareOneBudgetAndKeepExactControl", "legacyExhaustedPreflightDeadlineNeverLaunchesQuery", "legacyQueryDeadlineCannotTurnLateValidJSONIntoCompleteEmpty"])
with (out / "new-regressions.log").open("w") as log:
    log.write("HEAD " + sha + "\nOnly four new test cases; --skip-build\n")
    log.flush()
    p = subprocess.run(["swift", "test", "--skip-build", "--disable-xctest", "--filter", selected], cwd=held, stdout=log, stderr=subprocess.STDOUT, timeout=45)
    log.write("\nEXIT " + str(p.returncode) + "\n")
    assert p.returncode == 0
assert all(hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == value for name, value in current.items())
print("PR48 test-only equality and four new focused regressions PASS; no rebuild")
