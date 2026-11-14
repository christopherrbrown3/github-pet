"""Preliminary validation portability probe only; no mutable PR48 build objects used."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = root.parent / "qa-verify-940231d"
held = root.parent / "developer-timing"
out = root / "docs/qa/pr48-940231d"
out.mkdir(exist_ok=True)
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == "940231dc1a794dcf221449e8df1a441718b1ca3f"
objects = sorted((held / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
assert objects
with tempfile.TemporaryDirectory(prefix="qa48-validation-") as tmp:
    temp = pathlib.Path(tmp)
    # Adds only the module import needed when compiling the exact scope source out of its module.
    copy = temp / "MonitoringScope.swift"
    copy.write_text("import GitHubPetCore\n" + (source / "Sources/GitHubPetCore/MonitoringScope.swift").read_text())
    binary = temp / "probe"
    with (out / "validation.log").open("w") as log:
        log.write("SOURCE HEAD 940231dc1a794dcf221449e8df1a441718b1ca3f; only stable47 core objects for unchanged model dependencies\n")
        log.flush()
        p = subprocess.run(["swiftc", "-parse-as-library", "-I", str(held / ".build/debug/Modules"), str(copy),
            str(root / "scripts/qa/pr48-validation.swift"), *map(str, objects), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=60)
        assert p.returncode == 0
        p = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT, timeout=10)
        log.write("\nEXIT " + str(p.returncode) + "\n")
        assert p.returncode == 0
print("PR48 preliminary actual-type validation probe PASS; no local newline defect reproduced")
