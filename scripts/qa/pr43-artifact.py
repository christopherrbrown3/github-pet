"""Download and independently inspect the actual green PR43 CI artifact."""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
repo = "christopherrbrown3/github-pet"
sha, run_id = sys.argv[1:] if len(sys.argv) == 3 else ("f54d5a6deb1db6c6ec3e87361431d4222dbd6a64", "43606183925")
assert len(sha) == 40 and all(c in "0123456789abcdef" for c in sha) and run_id.isdigit()
short = sha[:7]
source = root.parent / ("qa-verify-" + short)
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == sha
count = subprocess.check_output(["git", "rev-list", "--count", "HEAD"], cwd=source, text=True).strip()
out = root / ("docs/qa/pr43-" + short)
with (out / "artifact-verification.log").open("w") as log:
    def run(argv, cwd=None, timeout=60):
        result = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        log.write(repr(argv) + "\n" + result.stdout + "EXIT " + str(result.returncode) + "\n")
        log.flush()
        assert result.returncode == 0, result.stdout
        return result.stdout
    state = json.loads(run(["gh", "run", "view", run_id, "--repo", repo, "--json", "headSha,status,conclusion,event,jobs"]))
    assert state["headSha"] == sha and state["conclusion"] == "success" and state["event"] == "pull_request"
    download = out / "download"
    download.mkdir()  # require a fresh directory; never reuse a developer artifact
    run(["gh", "run", "download", run_id, "--repo", repo, "--name", "GitHubPet-app", "--dir", str(download)])
    archive = download / ("GitHubPet-0.1.0-" + short + "-universal.zip")
    assert archive.exists()
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert archive.with_suffix(".zip.sha256").read_text().split()[0] == digest
    run(["shasum", "-a", "256", "-c", archive.name + ".sha256"], cwd=download)
    extracted = out / "extracted"
    extracted.mkdir()
    run(["ditto", "-x", "-k", str(archive), str(extracted)])
    app = extracted / "GitHubPet.app"
    run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app)])
    detail = run(["codesign", "-d", "--verbose=4", str(app)])
    assert "Signature=adhoc" in detail and "TeamIdentifier=not set" in detail
    assert set(run(["lipo", "-archs", str(app / "Contents/MacOS/GitHubPet")]).split()) == {"arm64", "x86_64"}
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key, value in {"CFBundleShortVersionString": "0.1.0", "CFBundleVersion": count, "GitHubPetSourceRevision": sha,
                       "CFBundleIdentifier": "dev.github-pet.GitHubPet", "LSMinimumSystemVersion": "13.0", "LSUIElement": True}.items():
        assert plist[key] == value, (key, plist[key])
        log.write("PASS " + key + "=" + str(value) + "\n")
    pack = app / "Contents/Resources/MascotPacks/mona-pet-v1"
    assert (pack / "manifest.json").is_file() and len(list((pack / "frames").glob("*.png"))) == 12
    source_pack = source / "assets/mascots/mona-pet-v1"
    for file in [pack / "manifest.json", *sorted((pack / "frames").glob("*.png"))]:
        assert file.read_bytes() == (source_pack / file.relative_to(pack)).read_bytes(), file
    log.write("PASS all bundled mascot files match exact source bytes\n")
    ci_log = run(["gh", "run", "view", run_id, "--repo", repo, "--log"], timeout=90)
    (out / "ci.log").write_text(ci_log)
    log.write("PASS artifact sha256=" + digest + "\n")
    (out / "artifact-summary.json").write_text(json.dumps({"head": sha, "run": run_id, "zip": archive.name, "sha256": digest, "plist": plist}, indent=2))
print("PR43 actual green CI artifact verification PASS")
