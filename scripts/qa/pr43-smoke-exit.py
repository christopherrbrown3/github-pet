"""Exercise smoke script process status with a usable report; no real Rosetta/app launch."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

source = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
with out.open("w") as log, tempfile.TemporaryDirectory(prefix="qa43-exit-") as tmp:
    base = pathlib.Path(tmp)
    log.write("HEAD " + subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True))
    (base / "scripts").mkdir()
    (base / "bin").mkdir()
    shutil.copy2(source / "scripts/intel-smoke.sh", base / "scripts/intel-smoke.sh")
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)
    executable(base / "bin/lipo", '#!/bin/sh\necho "x86_64 arm64"\n')
    executable(base / "bin/arch", '#!/bin/sh\nshift\nexec "$@"\n')
    app = base / "fixture.app/Contents/MacOS"
    app.mkdir(parents=True)
    results = []
    for status in [0, 86]:
        executable(app / "GitHubPet", '#!/bin/sh\nmkdir -p "$2"\nprintf "## 01-baseline\\nstate=Up to date badge=3 rows=3 demo=true\\n" > "$2/report.txt"\nexit ' + str(status) + '\n')
        result = subprocess.run(["zsh", "scripts/intel-smoke.sh", str(base / "fixture.app")], cwd=base,
            env=dict(os.environ, PATH=str(base / "bin") + ":" + os.environ["PATH"]), text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        log.write(f"child={status} smoke-exit={result.returncode}\n{result.stdout}\n")
        results.append(result.returncode)
    log.write("RESULT " + ("PASS: failed child rejected" if results[0] == 0 and results[1] != 0 else "FAIL: failed child accepted") + "\n")
    print("smoke child0/86 results:", results)
    sys.exit(0 if results[0] == 0 and results[1] != 0 else 1)
