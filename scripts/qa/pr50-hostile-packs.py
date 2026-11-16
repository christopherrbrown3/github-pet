"""PR50 (#40) functional QA: launch the built app with hostile custom mascot packs.

    python3 -I scripts/qa/pr50-hostile-packs.py <full-sha> <verify-worktree> <work-dir>

Each case copies the bundled pack and changes manifest.json (or the pack directory name),
then launches the real built app with GITHUB_PET_PACK_DIR in --render-snapshots mode. That
mode forces fixtures and a throwaway defaults suite and quits by itself. The script records
the app's raw stderr bytes and checks properties of the actual launch line. It does not
reimplement the sanitizer: expected text is written out by hand only for simple cases.
"""
import hashlib, json, os, time, pathlib, shutil, subprocess, sys, unicodedata

sha, verify, work = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
qa_root = pathlib.Path(__file__).resolve().parents[2]
out = qa_root / f"docs/qa/pr50-{sha[:7]}"
out.mkdir(parents=True, exist_ok=True)
app = verify / ".build/app/GitHubPet.app"
binary = app / "Contents/MacOS/GitHubPet"
source_pack = verify / "assets/mascots/mona-pet-v1"
prefs = pathlib.Path.home() / "Library/Preferences"
real_plist = prefs / "dev.github-pet.GitHubPet.plist"
ESC, CSI8 = "\x1b", "\u009b"
FB, CAP = "(unnamed pack)", 48

def case(name, id=None, dirname=None, mutate=None, expect=None, label=None):
    # label: hand-written predicate on the shown label, with a description
    return dict(name=name, id=id, dirname=dirname or name, mutate=mutate, expect=expect, label=label)

def bad_path(m):
    m["states"]["idle"]["frames"][0] = "../\n" + ESC + "[2J" + "‮evil.png"

def bad_missing(m):
    # A required state's frame names a missing file: the author-controlled path reaches the error text.
    m["states"]["idle"]["frames"][0] = "frames/" + ESC + "[31mmissing\nGitHubPet: trusted\u202Efile.png"

CASES = [
    case("normal", id="qa-normal-pack", expect="mascot pack qa-normal-pack loaded"),
    case("how-to", id="x‮evil\n" + ESC + "[31mGitHubPet: mascot pack trusted"),
    case("newline", id="line1\nGitHubPet: mascot pack trusted\r\nline3 line4 end"),
    case("ansi", id=ESC + "[31mred" + ESC + "[0m " + ESC + "]0;title\x07 " + CSI8 + "2J c1csi"),
    case("rtl", id="abc‮def‪ghi⁦jkl⁩‎mno‏؜end"),
    case("zero-width", id="a​b‌c‍d﻿e⁠f­g", expect="mascot pack abcdefg loaded"),
    case("long-ascii", id="A" * 600, expect="mascot pack " + "A" * CAP + "… loaded"),
    case("long-emoji", id="👨‍👩‍👧" * 120),
    case("combining", id="e" + "́" * 1000 + "tail"),
    case("scalar-cap-300", id="a" + "\u0301" * 300 + "pack-B",
         label=(lambda l: l.endswith("…") and "pack-B" not in l, "ends with … and drops pack-B")),
    case("scalar-cap-256", id="a" + "\u0301" * 255,
         label=(lambda l: not l.endswith("…") and len(l) == 256, "exactly 256 scalars kept, no …")),
    case("scalar-cap-257", id="a" + "\u0301" * 256,
         label=(lambda l: l.endswith("…") and len(l) == 257, "256 scalars kept plus …")),
    case("combining-many", id=("e" + "́" * 10) * 60),
    case("empty-after", id="‮​\n\t  " + ESC + "\x00 ", expect="mascot pack " + FB + " loaded"),
    case("empty", id="", expect="mascot pack " + FB + " loaded"),
    case("hostile-dir", id="qa-dir-pack", dirname="pack\n" + ESC + "[2J‮dir"),
    case("pending-space-boundary", id="a" + "\u0301" * 254 + " bc",
         label=(lambda l: l == "a" + "\u0301" * 254 + "…", "a + 254 marks + … with no space or bc")),
    case("deep-path", id="qa-deep-pack",
         dirname="deep/" + "/".join(f"level{i:02d}-padding-component" for i in range(10)) + "/qa-deep-pack-dir"),
    case("deep-path-1000", id="qa-deep-1000",
         dirname="deep1000/" + "/".join(f"d{i:03d}-" + "x" * 40 for i in range(15)) + "/qa-deep-1000-dir"),
    case("hostile-path", id="qa-hostile-path",
         dirname="hp/" + "/".join(f"level{i:02d}-padding-component" for i in range(4))
                 + "/x\n" + ESC + "[31mevil\u202E\u200Bdir" + "/qa-hostile-path-dir"),
    case("error-path", id="qa-error-path", mutate=bad_path),
    case("error-missing", id="qa-error-missing", mutate=bad_missing),
]

def snapshot():
    domains = subprocess.run(["defaults", "domains"], capture_output=True, text=True).stdout
    names = sorted(d.strip() for d in domains.split(",") if d.strip().startswith("dev.github-pet."))
    files = sorted(p.name for p in prefs.glob("dev.github-pet.*"))
    real = hashlib.sha256(real_plist.read_bytes()).hexdigest() if real_plist.exists() else "absent"
    return names, files, real

def visible(s):  # escape everything non-printable so the log shows exactly what was emitted
    return "".join(c if c.isprintable() and unicodedata.category(c) != "Cf" else f"\\u{{{ord(c):04X}}}" for c in s)

assert binary.exists(), binary
plist = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :GitHubPetSourceRevision", str(app / "Contents/Info.plist")],
                       capture_output=True, text=True).stdout.strip()
assert plist == sha, (plist, sha)
log = [f"# PR50 hostile pack launches, {sha}",
       f"binary sha256 {hashlib.sha256(binary.read_bytes()).hexdigest()}",
       "mode: GITHUB_PET_PACK_DIR=<pack> GitHubPet --render-snapshots <dir> (fixtures, throwaway suite, self-quit)", ""]
results, failures = {}, 0
saved_before = subprocess.run(["pgrep", "-f", "/github-pet-builds/"], capture_output=True, text=True).stdout.split()
only = set(filter(None, os.environ.get("QA_CASES", "").split(",")))
for c in CASES:
    if only and c["name"] not in only: continue
    pack = work / "packs" / c["dirname"]
    if pack.exists(): shutil.rmtree(pack)
    shutil.copytree(source_pack, pack)
    manifest = json.loads((pack / "manifest.json").read_text())
    stored = c["id"]
    manifest["id"] = stored
    if c["mutate"]: c["mutate"](manifest)
    (pack / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=True))
    assert json.loads((pack / "manifest.json").read_text())["id"] == stored  # what the app reads
    render = work / "render" / c["name"]
    shutil.rmtree(render, ignore_errors=True)
    before = snapshot()
    proc = subprocess.Popen([str(binary), "--render-snapshots", str(render)], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env={"HOME": str(pathlib.Path.home()), "PATH": "/usr/bin:/bin", "GITHUB_PET_PACK_DIR": str(pack)})
    stdout, stderr = proc.communicate(timeout=300)
    p = subprocess.CompletedProcess(proc.args, proc.returncode, stdout, stderr)
    time.sleep(1)
    own = prefs / f"dev.github-pet.render-snapshots.{proc.pid}.plist"
    leftover = own.exists() and subprocess.run(["defaults", "read", own.stem], capture_output=True, text=True).stdout.strip() not in ("", "{\n}")
    after = snapshot()
    err = p.stderr.decode("utf-8", errors="replace")
    (out / f"stderr-{c['name']}.bin").write_bytes(p.stderr)
    lines = [l for l in err.split("\n") if l]
    launch = [l for l in lines if l.startswith("GitHubPet: mascot")]
    problems = []
    if p.returncode != 0: problems.append(f"exit {p.returncode}")
    if len(launch) != 1: problems.append(f"{len(launch)} launch lines")
    stray = [l for l in lines if not l.startswith("GitHubPet: mascot")]
    if any("trusted" in l or "pwned" in l or "line3" in l for l in stray): problems.append("injected text on its own stderr line")
    line = launch[0] if launch else ""
    bad = [c2 for c2 in line if unicodedata.category(c2) in ("Cc", "Cf", "Zl", "Zp", "Co", "Cn", "Cs")]
    if bad: problems.append("control/format chars in launch line: " + ",".join(f"U+{ord(b):04X}" for b in sorted(set(bad))))
    if ESC in err or CSI8 in err: problems.append("ESC/CSI anywhere in stderr")
    if "‮" in err: problems.append("U+202E anywhere in stderr")
    if c["expect"] and c["expect"] not in line: problems.append(f"expected {c['expect']!r}")
    if not c["mutate"]:
        if " loaded from " not in line: problems.append("pack did not load")
        label = line.removeprefix("GitHubPet: mascot pack ").split(" loaded from ")[0]
        core = label.removesuffix("…")
        # Rough grapheme count for these inputs: combining marks, ZWJ and the scalar after a ZWJ join.
        zwj = chr(0x200D)
        clusters = sum(1 for i, ch in enumerate(core) if not unicodedata.combining(ch) and ch != zwj and (i == 0 or core[i - 1] != zwj))
        if clusters > CAP: problems.append(f"label has about {clusters} graphemes, over {CAP}")
        if len(label.encode()) > 4 * (256 + 1): problems.append("label exceeds the scalar pre-cap")
        shown_path = line.split(" loaded from ", 1)[1] if " loaded from " in line else ""
        if len(shown_path) > 160 + 2: problems.append(f"shown path has {len(shown_path)} code points, over 160")
        if c["name"].startswith(("deep", "hostile-path")) and not shown_path.endswith(pathlib.PurePath(c["dirname"]).name):
            problems.append("shown path lost the pack directory name")
        if c["label"] and not c["label"][0](label): problems.append("label check failed: " + c["label"][1])
        pngs = sorted(render.glob("*.png"))
        if not pngs: problems.append("no snapshot PNG rendered")
    else:
        if "pack rejected" not in line: problems.append("hostile pack was not rejected")
    if leftover: problems.append(f"own throwaway domain {own.stem} left with content")
    removed = set(before[1]) - set(after[1])
    if removed: problems.append(f"pre-existing domains removed {removed}")
    empty_file = own.exists() and not leftover
    if before[2] != after[2]: problems.append("real preferences changed (saved app also writes; attribute by hand)")
    failures += bool(problems)
    results[c["name"]] = dict(stored_id=stored, exit=p.returncode, empty_domain_file_left=empty_file, launch_line=line, problems=problems,
                              renders=len(list(render.glob("*.png"))))
    log += [f"## {c['name']}", f"stored id (escaped): {visible(stored)[:200]}", f"exit {p.returncode}; renders {results[c['name']]['renders']}; empty own domain plist left: {empty_file}",
            f"launch line (escaped): {visible(line)}", f"launch line code points: {len(line)}, utf8 bytes {len(line.encode())}",
            "result: " + ("ok" if not problems else "FAIL " + "; ".join(problems)), ""]
saved_after = subprocess.run(["pgrep", "-f", "/github-pet-builds/"], capture_output=True, text=True).stdout.split()
log.append(f"saved build pids before {saved_before} after {saved_after}")
if saved_before != saved_after: failures += 1
log.append(f"mechanical failures: {failures} (grapheme cap and visual output also judged by hand)")
(out / "hostile-packs.md").write_text("\n".join(log) + "\n")
(out / "hostile-packs.json").write_text(json.dumps(results, indent=1, ensure_ascii=True) + "\n")
print("\n".join(log))
sys.exit(1 if failures else 0)
