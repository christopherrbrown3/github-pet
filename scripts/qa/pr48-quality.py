import hashlib
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
held = root.parent / "developer-scope-core"
out = root / "docs/qa/pr48-1d5a911"
out.mkdir(exist_ok=True)
sha = "1d5a9115d6ff338a308813cb01e1a2422824e606"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=held, text=True).strip() == sha
assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=held, text=True).strip()
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects + [held / ".build/debug/Modules/GitHubPetCore.swiftmodule"]}
(out / "held-build-hashes.json").write_text(json.dumps(before, indent=2))
with tempfile.TemporaryDirectory(prefix="qa48-quality-") as tmp:
    for source, label in [("pr48-legacy-exit.swift", "same-exit-repro-after"), ("pr48-quality.swift", "quality")]:
        binary = pathlib.Path(tmp) / label
        with (out / (label + ".log")).open("w") as log:
            log.write("HEAD " + sha + "\nNORMAL import; immutable held build\n")
            log.flush()
            p = subprocess.run(["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"), str(root / "scripts/qa" / source), *map(str, objects), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=60)
            assert p.returncode == 0
            p = subprocess.run([str(binary), tmp], stdout=log, stderr=subprocess.STDOUT, timeout=30)
            log.write("\nEXIT " + str(p.returncode) + "\n")
            assert p.returncode == 0
        print(label, "PASS", flush=True)
assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == value for p, value in before.items())
(out / "held-build-unchanged.txt").write_text("PASS all core module/object hashes unchanged after focused quality probes\n")
