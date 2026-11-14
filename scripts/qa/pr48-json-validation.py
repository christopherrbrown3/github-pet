"""Original-head JSON-path negative probe. Never links mutable PR48 objects."""
import hashlib
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = root.parent / "qa-verify-940231d"
held = root.parent / "developer-timing"
out = root / "docs/qa/pr48-940231d"
names = ["MonitoringScope", "ScopedGitHub", "CommandBudget", "GitHubCLI"]
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
assert objects
with tempfile.TemporaryDirectory(prefix="qa48-json-") as tmp:
    temp = pathlib.Path(tmp)
    copies = []
    hashes = []
    for name in names:
        original = source / ("Sources/GitHubPetCore/" + name + ".swift")
        text = original.read_text()
        copy = temp / (name + ".swift")
        # Unchanged declarations/implementations. Import supplies only unchanged model dependencies.
        copy.write_text("import GitHubPetCore\n" + text)
        copies.append(copy)
        hashes.append(hashlib.sha256(original.read_bytes()).hexdigest() + " " + str(original))
    (out / "json-probe-source-hashes.txt").write_text("\n".join(hashes) + "\n")
    with (out / "json-validation.log").open("w") as log:
        log.write("EXACT source940231dc1a794dcf221449e8df1a441718b1ca3f; four original declarations files +module imports only; held47 unchanged dependencies; no mutable48objects\n")
        log.flush()
        p = subprocess.run(["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"), *map(str, copies),
            str(root / "scripts/qa/pr48-json-validation.swift"), *map(str, objects), "-o", str(temp / "probe")], stdout=log, stderr=subprocess.STDOUT, timeout=90)
        assert p.returncode == 0
        p = subprocess.run([str(temp / "probe")], stdout=log, stderr=subprocess.STDOUT, timeout=10)
        log.write("\nPROBE EXIT " + str(p.returncode) + "\n")
        assert p.returncode == 0
print("Original48 JSON-path negative probe complete; inspect calibrated results")
