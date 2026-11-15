import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
held = root.parent / "developer-scope-core"
sha = "e2a11a559bfbfb791fcd68cd4aa37d77f1f4ce72"
out = root / "docs/qa/pr48-e2a11a5"
out.mkdir(exist_ok=True)
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=held, text=True).strip() == sha
assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=held, text=True).strip()
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
assert objects
tracked = objects + [held / ".build/debug/Modules/GitHubPetCore.swiftmodule"]
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
(out / "held-build-hashes.json").write_text(json.dumps(before, indent=2))
def run(name, argv, limit):
    with (out / (name + ".log")).open("w") as log:
        log.write("HEAD " + sha + "\nNORMAL import; held source/build only\n")
        log.flush()
        try:
            p = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=limit)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = 124
        log.write("\nEXIT " + str(code) + "\n")
    print(name, "exit", code, flush=True)
    return code
with tempfile.TemporaryDirectory(prefix="qa48-final-") as tmp:
    temp = pathlib.Path(tmp)
    for source, args, limit in [("pr48-json-validation.swift", ["--fixed"], 10), ("pr48-adversarial.swift", [str(temp), sys.executable], 75)]:
        name = "json-after" if "json" in source else "adversarial"
        binary = temp / name
        code = run(name + "-compile", ["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"),
            str(root / "scripts/qa" / source), *map(str, objects), "-o", str(binary)], 90)
        if code: sys.exit(code)
        code = run(name, [str(binary), *args], limit)
        if code: sys.exit(code)
assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == v for p, v in before.items())
(out / "held-build-unchanged.txt").write_text("PASS all linked object/module hashes unchanged after QA; no source/build mutations\n")
