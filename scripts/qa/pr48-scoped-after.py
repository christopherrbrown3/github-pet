import hashlib
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
held = root.parent / "developer-scope-core"
source = root.parent / "qa-verify-4b9130f"
out = root / "docs/qa/pr48-4b9130f"
out.mkdir(exist_ok=True)
sha = "4b9130f82b1299929b1bc0c14d1f446cab4f91a1"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=held, text=True).strip() == sha
assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=held, text=True).strip()
names = subprocess.check_output(["git", "diff", "--name-only", "97e797a", "HEAD"], cwd=source, text=True).splitlines()
assert names == ["Sources/GitHubPetCore/ScopedGitHub.swift", "Tests/GitHubPetCoreTests/MonitoringScopeTests.swift"]
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects + [held / ".build/debug/Modules/GitHubPetCore.swiftmodule"]}
(out / "source-build-check.json").write_text(json.dumps({"head": sha, "changed_files": names, "hashes": before}, indent=2))
with tempfile.TemporaryDirectory(prefix="qa48-scoped-after-") as tmp, (out / "scoped-errors-after.log").open("w") as log:
    binary = pathlib.Path(tmp) / "probe"
    log.write("HEAD " + sha + "\nNORMAL import; exact completed held build\n")
    log.flush()
    p = subprocess.run(["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"), str(root / "scripts/qa/pr48-scoped-errors.swift"), *map(str, objects), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=60)
    assert p.returncode == 0
    p = subprocess.run([str(binary), "--fixed"], stdout=log, stderr=subprocess.STDOUT, timeout=20)
    log.write("\nEXIT " + str(p.returncode) + "\n")
    assert p.returncode == 0
assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == value for p, value in before.items())
(out / "held-build-unchanged.txt").write_text("PASS linked core objects/module unchanged before/after affected parser/client matrix\n")
print("PR48 scoped errors positive-after matrix PASS; source/build verified")
