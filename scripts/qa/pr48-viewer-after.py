import hashlib
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
held = root.parent / "developer-scope-core"
source = root.parent / "qa-verify-52d5124"
out = root / "docs/qa/pr48-52d5124"
out.mkdir(exist_ok=True)
sha = "52d5124384817b63dc6d3ee2d58dcd4b9491ba45"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=held, text=True).strip() == sha
assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=held, text=True).strip()
names = subprocess.check_output(["git", "diff", "--name-only", "4b9130f", "HEAD"], cwd=source, text=True).splitlines()
assert names == ["Sources/GitHubPetCore/ScopedGitHub.swift", "Tests/GitHubPetCoreTests/MonitoringScopeTests.swift"]
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects + [held / ".build/debug/Modules/GitHubPetCore.swiftmodule"]}
(out / "source-build-check.json").write_text(json.dumps({"head": sha, "changed_files": names, "hashes": before}, indent=2))
with tempfile.TemporaryDirectory(prefix="qa48-viewer-after-") as tmp, (out / "viewer-login-after.log").open("w") as log:
    binary = pathlib.Path(tmp) / "probe"
    log.write("HEAD " + sha + "\nNORMAL import; exact immutable held source/build\n")
    log.flush()
    subprocess.run(["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"), str(root / "scripts/qa/pr48-viewer-login.swift"), *map(str, objects), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
    subprocess.run([str(binary), "--fixed"], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=20)
assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == value for p, value in before.items())
(out / "held-build-unchanged.txt").write_text("PASS linked module/core object hashes unchanged before/after focused viewer parser/client probes\n")
print("PR48 focused viewer-login positive-after and guard checks PASS")
