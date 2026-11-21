#!/bin/zsh
# Exercises update-cask.sh with fake release ZIPs: no network, Homebrew or release.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

make_zip() { # release-version asset-name
  rm -rf "$scratch/z"; mkdir -p "$scratch/z/GitHubPet.app/Contents"
  python3 -I - "$scratch/z/GitHubPet.app/Contents/Info.plist" "$1" <<'PY'
import plistlib, sys
plistlib.dump({"GitHubPetReleaseVersion": sys.argv[2]}, open(sys.argv[1], "wb"))
PY
  (cd "$scratch/z" && ditto -c -k --keepParent GitHubPet.app "$scratch/$2")
}
fresh_cask() { cp packaging/homebrew/Casks/github-pet.rb "$scratch/cask.rb"; }
run() { scripts/update-cask.sh "$@" 2>&1; }

asset=GitHubPet-0.1.0-abc1234-universal.zip
make_zip 0.1.0-beta.5 "$asset"
sha=$(shasum -a 256 "$scratch/$asset" | cut -d' ' -f1)
fresh_cask
run v0.1.0-beta.5 "$scratch/$asset" "$scratch/cask.rb" >/dev/null || fail "a matching release was refused"
grep -q '^  version "0.1.0-beta.5"$' "$scratch/cask.rb" || fail "version not rewritten"
grep -q "^  sha256 \"$sha\"\$" "$scratch/cask.rb" || fail "sha256 not rewritten"
grep -q "download/v#{version}/$asset\"\$" "$scratch/cask.rb" || fail "asset name not rewritten"
[[ $(diff <(sed 's/[0-9a-f]\{64\}//' packaging/homebrew/Casks/github-pet.rb) <(sed 's/[0-9a-f]\{64\}//' "$scratch/cask.rb") | grep -c "^>") == 2 ]] || fail "more than version, sha256 and url changed"
cp "$scratch/cask.rb" "$scratch/once.rb"
run v0.1.0-beta.5 "$scratch/$asset" "$scratch/cask.rb" >/dev/null || fail "re-running was refused"
cmp -s "$scratch/once.rb" "$scratch/cask.rb" || fail "re-running changed the cask"

echo "$sha  $asset" > "$scratch/$asset.sha256"
run v0.1.0-beta.5 "$scratch/$asset" "$scratch/cask.rb" >/dev/null || fail "a matching .sha256 was refused"
echo "$(printf 0%.0s {1..64})  $asset" > "$scratch/$asset.sha256"
fresh_cask
run v0.1.0-beta.5 "$scratch/$asset" "$scratch/cask.rb" >/dev/null && fail "a mismatching .sha256 was accepted"
rm "$scratch/$asset.sha256"

run v0.1.0-beta.6 "$scratch/$asset" "$scratch/cask.rb" >/dev/null && fail "a tag that disagrees with the app was accepted"
run notatag "$scratch/$asset" "$scratch/cask.rb" >/dev/null && fail "a malformed tag was accepted"
run v0.1.0-beta.5 "$scratch/missing.zip" "$scratch/cask.rb" >/dev/null && fail "a missing ZIP was accepted"
cp "$scratch/$asset" "$scratch/other.zip"
run v0.1.0-beta.5 "$scratch/other.zip" "$scratch/cask.rb" >/dev/null && fail "a misnamed ZIP was accepted"
fresh_cask; cp "$scratch/cask.rb" "$scratch/before.rb"
echo 'cask "x" do end' > "$scratch/bad.rb"
run v0.1.0-beta.5 "$scratch/$asset" "$scratch/bad.rb" >/dev/null && fail "a cask without the expected lines was accepted"
cmp -s "$scratch/cask.rb" "$scratch/before.rb" || fail "a refused run modified the cask"

(( failures == 0 )) && echo "update-cask checks passed" || { echo "$failures update-cask check(s) failed" >&2; exit 1; }
