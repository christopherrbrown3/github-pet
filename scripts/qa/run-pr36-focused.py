"""Bounded independent probes; does not edit the implementation checkout."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
source = root.parent / "qa-verify-8c462b2"
out = root / "docs/qa/pr36-8c462b2"
sha = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
assert sha == "8c462b2673af0b6cafae7018d3e132f0b906d2d8", sha

def run(name, argv, timeout):
    with (out / (name + ".log")).open("w") as log:
        log.write("HEAD " + sha + "\nCOMMAND " + repr(argv) + "\n")
        log.flush()
        try:
            p = subprocess.run(argv, cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            code = p.returncode
        except subprocess.TimeoutExpired:
            code = 124
        log.write("\nEXIT " + str(code) + "\n")
    print(name, "exit", code, flush=True)
    return code

if sys.argv[1:] == ["test"]:
    sys.exit(run("focused-tests", ["swift", "test", "--skip-build", "--filter", "descendantHoldingThePipeDoesNotLeakReadsOrDescriptors|IncidentMarkerSpecTests|invalidIncidentRejectsWholePayload|invalidIDsHaveNoURL|snapshotLargerThanMemoryNeverReplays|burstEndsWhenTheMarkerIsHidden"], 75))

objects = sorted((source / ".build/debug/GitHubPetCore.build").glob("*.swift.o"))
if sys.argv[1:] == ["stills"]:
    binary = out / "stills-probe"
    code = run("compile-stills", ["swiftc", "-parse-as-library", "-I", str(source / ".build/debug/Modules"),
        *[str(source / ("Sources/GitHubPet/" + name + ".swift")) for name in ["AppModel", "LaunchOptions", "MascotView", "IncidentMarkerView"]],
        str(root / "scripts/qa/pr36-stills.swift"), *map(str, objects), "-o", str(binary)], 100)
    if not code:
        code = run("stills", [str(binary), str(out), str(source / "assets/mascots/mona-pet-v1")], 45)
    sys.exit(code)
binary = out / "focused-probe"
code = run("compile-probe", ["swiftc", "-parse-as-library", "-I", str(source / ".build/debug/Modules"),
    str(source / "Sources/GitHubPet/AppModel.swift"), str(source / "Sources/GitHubPet/LaunchOptions.swift"),
    str(root / "scripts/qa/pr36-focused.swift"), *map(str, objects), "-o", str(binary)], 100)
if not code:
    code = run("appmodel-probe", [str(binary)], 30)
sys.exit(code)
