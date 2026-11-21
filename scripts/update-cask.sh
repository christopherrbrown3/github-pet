#!/bin/zsh
# Rewrite version, sha256 and asset name in the Homebrew cask from a release ZIP.
# No network and no publishing: copy the result into the tap by hand.
#
#   scripts/update-cask.sh <tag> <zip> [cask]     e.g. v0.1.0-beta.5 GitHubPet-0.1.0-abc1234-universal.zip
#   CASK defaults to packaging/homebrew/Casks/github-pet.rb
set -euo pipefail
cd "${0:A:h}/.."

(( $# == 2 || $# == 3 )) || { echo "usage: $0 <tag> <zip> [cask]" >&2; exit 64; }
tag=$1 zip=$2 cask=${3:-packaging/homebrew/Casks/github-pet.rb}
[[ $tag =~ '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ]] || { echo "'$tag' is not a release tag like v0.1.0 or v0.1.0-beta.5" >&2; exit 64; }
[[ -f $zip ]] || { echo "no such ZIP: $zip" >&2; exit 66; }
[[ -f $cask ]] || { echo "no such cask: $cask" >&2; exit 66; }
asset=${zip:t}
[[ $asset =~ '^GitHubPet-[0-9A-Za-z.-]+-universal\.zip$' ]] || { echo "'$asset' is not a GitHubPet-<version>-<commit>-universal.zip" >&2; exit 64; }
version=${tag#v}

# The tag must agree with the app inside the ZIP (the same check release-appcast.sh makes).
plist=$(unzip -Z1 "$zip" | grep -m1 '^GitHubPet\.app/Contents/Info\.plist$') || { echo "ZIP has no GitHubPet.app" >&2; exit 65; }
inside=$(unzip -p "$zip" "$plist" | python3 -I -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read()).get("GitHubPetReleaseVersion", ""))')
[[ $inside == "$version" ]] || { echo "tag $tag disagrees with the app's release version '${inside:-none}'" >&2; exit 65; }

sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
if [[ -f $zip.sha256 ]]; then
  [[ $(cut -d' ' -f1 < "$zip.sha256") == "$sha" ]] || { echo "$zip.sha256 does not match the ZIP" >&2; exit 65; }
fi

scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT
VERSION=$version SHA=$sha ASSET=$asset python3 -I - "$cask" > "$scratch" <<'PY'
import os, re, sys
text = open(sys.argv[1]).read()
def sub(pattern, repl):
    global text
    text, n = re.subn(pattern, lambda m: repl(m), text, count=1, flags=re.M)
    if n != 1:
        sys.exit(f"cask has no line matching {pattern}")
sub(r'^(  version )"[^"]*"$', lambda m: f'{m[1]}"{os.environ["VERSION"]}"')
sub(r'^(  sha256 )"[0-9a-f]{64}"$', lambda m: f'{m[1]}"{os.environ["SHA"]}"')
sub(r'^(  url ".*/download/v#\{version\}/)[^/"]+"$', lambda m: f'{m[1]}{os.environ["ASSET"]}"')
sys.stdout.write(text)
PY
cat "$scratch" > "$cask"
echo "updated $cask: version $version, $asset, sha256 $sha"
