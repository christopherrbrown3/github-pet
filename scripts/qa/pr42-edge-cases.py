"""Bounded independent native edge probes using a completed exact-head SwiftPM build."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
build_source = pathlib.Path(sys.argv[1]).resolve()
sha = sys.argv[2]
short = sha[:7]
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=build_source, text=True).strip() == sha
out = root / ("docs/qa/pr42-" + short)
out.mkdir(exist_ok=True)
preview = sys.argv[3:] == ["preview"]
binary = out / ("preview-probe" if preview else "edge-probe")
objects = sorted((build_source / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
objects += [p for p in sorted((build_source / ".build/debug/GitHubPet.build").glob("*.swift.o")) if p.name != "GitHubPetApp.swift.o"]
assert objects

def run(name, argv, timeout):
    with (out / (name + ".log")).open("w") as log:
        log.write("HEAD " + sha + "\n")
        log.flush()
        try:
            p = subprocess.run(argv, cwd=build_source, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = 124
        log.write("\nEXIT " + str(code) + "\n")
    print(name, "exit", code, flush=True)
    return code

code = run("compile-preview" if preview else "compile-edge", ["swiftc", "-parse-as-library", "-I", str(build_source / ".build/debug/Modules"),
    str(root / ("scripts/qa/pr42-preview.swift" if preview else "scripts/qa/pr42-edge-cases.swift")), *map(str, objects), "-o", str(binary)], 60)
if code:
    sys.exit(code)
if preview:
    sys.exit(run("preview", [str(binary), str(build_source / "assets/mascots/mona-pet-v1")], 30))
codes = [run("transparent", [str(binary), "transparent"], 10), run("drops", [str(binary), "drops"], 15)]
sys.exit(0 if codes == [0, 0] else 1)
