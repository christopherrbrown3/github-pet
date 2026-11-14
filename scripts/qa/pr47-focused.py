"""Compile a disclosed one-line QA clock seam against immutable exact-head core objects."""
import difflib
import hashlib
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = root.parent / "qa-verify-bb44d7b"
held = root.parent / "developer-timing"
out = root / "docs/qa/pr47-bb44d7b"
out.mkdir(exist_ok=True)
sha = "bb44d7b47c300793b7a9ab30c73a9844b5f16f82"
for folder in [source, held]:
    assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=folder, text=True).strip() == sha
    assert not subprocess.check_output(["git", "status", "--porcelain"], cwd=folder, text=True).strip()
original = (source / "Sources/GitHubPet/AppModel.swift").read_text()
needle = "    let clockOffset: TimeInterval"
assert original.count(needle) == 1
modified = original.replace(needle, "    var clockOffset: TimeInterval")
(out / "clock-seam.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), modified.splitlines(True), fromfile="exact-head/AppModel.swift", tofile="QA-copy/AppModel.swift")))
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
assert objects
fingerprints = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in objects}
(out / "core-object-hashes.txt").write_text("\n".join(v + " " + k for k, v in fingerprints.items()) + "\n")
def run(name, argv, limit):
    with (out / (name + ".log")).open("w") as log:
        log.write("HEAD " + sha + "\n")
        log.flush()
        try:
            p = subprocess.run(argv, cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=limit)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = 124
        log.write("\nEXIT " + str(code) + "\n")
    print(name, "exit", code, flush=True)
    return code
with tempfile.TemporaryDirectory(prefix="qa47-clock-") as tmp:
    copy = pathlib.Path(tmp) / "AppModel.swift"
    copy.write_text(modified)
    binary = pathlib.Path(tmp) / "probe"
    code = run("compile", ["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"),
        str(copy), str(source / "Sources/GitHubPet/LaunchOptions.swift"), str(root / "scripts/qa/pr47-freshness.swift"),
        *map(str, objects), "-o", str(binary)], 90)
    if not code:
        code = run("appmodel-sequence", [str(binary)], 30)
    assert all(hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() == value for p, value in fingerprints.items())
    sys.exit(code)
