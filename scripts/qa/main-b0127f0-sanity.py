"""Final read-only artifact sanity; no build, launch or settings changes."""
import hashlib
import pathlib
import plistlib
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parents[2]
out = root / "docs/qa/main-b0127f0"
out.mkdir(exist_ok=True)
stable = pathlib.Path("/Users/chris/github-pet-builds/b0127f0")
sha = "b0127f00e4dec92b5b9111a46b76c7191334706f"
digest = "f427650c9624b64dc6a89871ffd952342dea429df10441c34ccf5968cf6952a5"
app = stable / "GitHubPet.app"
archive = stable / "GitHubPet-0.1.0-b0127f0-universal.zip"
with (out / "sanity.log").open("w") as log:
    def run(argv, cwd=None, timeout=30):
        p = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        log.write(repr(argv) + "\n" + p.stdout + "EXIT " + str(p.returncode) + "\n")
        log.flush()
        assert p.returncode == 0, p.stdout
        return p.stdout
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == digest
    assert archive.with_suffix(".zip.sha256").read_text().split()[0] == digest
    run(["shasum", "-a", "256", "-c", archive.name + ".sha256"], cwd=stable)
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        files = [i for i in z.infolist() if i.filename.startswith("GitHubPet.app/") and not i.is_dir()]
        assert files
        for info in files:
            assert z.read(info) == (stable / info.filename).read_bytes(), info.filename
        log.write(f"PASS ZIP integrity and all {len(files)} app file bytes equal stable extracted app\n")
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    detail = run(["codesign", "-d", "--verbose=4", str(app)])
    assert "Signature=adhoc" in detail and "TeamIdentifier=not set" in detail
    assert set(run(["lipo", "-archs", str(app / "Contents/MacOS/GitHubPet")]).split()) == {"x86_64", "arm64"}
    p = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert p["GitHubPetSourceRevision"] == sha and p["CFBundleVersion"] == "71"
    assert p["CFBundleShortVersionString"] == "0.1.0" and p["CFBundleIdentifier"] == "dev.github-pet.GitHubPet"
    assert p["LSUIElement"] is True and p["LSMinimumSystemVersion"] == "13.0"
    source = root.parent / "qa-verify-561fafc"
    assert run(["git", "rev-list", "--count", sha], cwd=source).strip() == "71"
    tree = run(["git", "rev-parse", sha + "^{tree}"], cwd=source).strip()
    assert tree == run(["git", "rev-parse", "HEAD^{tree}"], cwd=source).strip() == "c69eba8f2eab2696a11f9597e499e842ffaa70dc"
    pack = app / "Contents/Resources/MascotPacks/mona-pet-v1"
    frames = list((pack / "frames").glob("*.png"))
    assert len(frames) == 12
    for file in [pack / "manifest.json", *frames]:
        assert file.read_bytes() == (source / "assets/mascots/mona-pet-v1" / file.relative_to(pack)).read_bytes()
    ci_log = run(["gh", "run", "view", "43609749683", "--repo", "christopherrbrown3/github-pet", "--log"], timeout=60)
    (out / "main-ci.log").write_text(ci_log)
    assert digest in ci_log and sha in ci_log
    line = next(line for line in ci_log.splitlines() if "Intel slice smoke (Rosetta)" in line and "intel-smoke: x86_64 slice ran the snapshot scenario under Rosetta" in line)
    log.write("PASS actual main CI Rosetta execution: " + line + "\n")
    log.write("PASS final checksum/signature/architectures/plist/build/tree/pack/file sanity; no launch\n")
print("Final main b0127f0 independent sanity PASS")
