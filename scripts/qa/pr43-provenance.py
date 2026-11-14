"""Independent bounded packaging guards; never compiles or changes source checkout."""
import os
import pathlib
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
source = root.parent / "qa-verify-f54d5a6"
out = root / "docs/qa/pr43-f54d5a6"
expected = "f54d5a6deb1db6c6ec3e87361431d4222dbd6a64"
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == expected

with (out / "provenance.log").open("w") as log:
    def run(args, cwd=source, env=None, code=0):
        result = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        log.write(repr(args) + "\n" + result.stdout + "EXIT " + str(result.returncode) + "\n")
        log.flush()
        assert result.returncode == code, result.stdout
        return result.stdout
    run(["zsh", "-n", "scripts/build-app.sh", "scripts/package-zip.sh", "scripts/test-packaging.sh"])
    run(["zsh", "scripts/test-packaging.sh"])
    # Extra independent missing-Git guard. The fake Swift would leave a marker if invoked.
    with tempfile.TemporaryDirectory(prefix="qa43-provenance-") as tmp:
        folder = pathlib.Path(tmp)
        (folder / "scripts").mkdir()
        (folder / "bin").mkdir()
        for name in ["build-app.sh", "package-zip.sh"]:
            shutil.copy2(source / "scripts" / name, folder / "scripts" / name)
        shutil.copy2(source / "VERSION", folder / "VERSION")
        sentinel = folder / "compiler-invoked"
        swift = folder / "bin/swift"
        swift.write_text('#!/bin/sh\ntouch "' + str(sentinel) + '"\nexit 86\n')
        swift.chmod(0o755)
        env = dict(os.environ, PATH=str(folder / "bin") + ":" + os.environ["PATH"])
        for name in ["build-app.sh", "package-zip.sh"]:
            text = run(["zsh", "scripts/" + name], cwd=folder, env=env, code=65)
            assert "requires a Git checkout with complete history" in text
            assert not sentinel.exists() and not (folder / ".build").exists()
            log.write("PASS missing Git history " + name + ": rejected before Swift/output\n")
    full_count = int(run(["git", "rev-list", "--count", "HEAD"]).strip())
    assert full_count == 51
    log.write("PASS independent complete-history count=51\n")
print("PR43 provenance guards PASS (six existing + two missing-history cases)")
