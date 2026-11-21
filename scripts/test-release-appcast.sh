#!/bin/zsh
# Exercises release-appcast.sh with a fake signer and a fake app: no Keychain, key or network.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
key=$(grep -v '^#' Tests/fixtures/sparkle-test-public-key.txt | tr -d '[:space:]')
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# The script reads the committed key file; give it a scratch checkout holding the test key.
mkdir -p "$scratch/repo/scripts" "$scratch/repo/updates"
cp scripts/release-appcast.sh "$scratch/repo/scripts/"
# Start from an empty channel, never the live updates/appcast.xml: the test must not depend on which
# releases are already published (build numbers in the fixtures are compared against it).
cat > "$scratch/repo/updates/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>GitHub Pet</title>
        <link>https://github.com/christopherrbrown3/github-pet</link>
        <description>GitHub Pet releases. Written by scripts/release-appcast.sh; no releases are signed yet.</description>
        <language>en</language>
    </channel>
</rss>
XML
# The committed appcast, whatever it holds, must stay well-formed XML.
python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1])' updates/appcast.xml \
  || fail "committed updates/appcast.xml is not valid XML"
echo "$key" > "$scratch/repo/updates/sparkle-public-ed-key.txt"
cat > "$scratch/signer" <<'SH'
#!/bin/sh
echo 'sparkle:edSignature="dGVzdC1zaWduYXR1cmU=" length="1234"'
SH
chmod +x "$scratch/signer"

make_zip() { # version build key
  rm -rf "$scratch/z"; mkdir -p "$scratch/z/GitHubPet.app/Contents"
  python3 - "$scratch/z/GitHubPet.app/Contents/Info.plist" "$1" "$2" "$3" <<'PY'
import plistlib, sys
info = {"GitHubPetReleaseVersion": sys.argv[2], "CFBundleVersion": sys.argv[3], "SUPublicEDKey": sys.argv[4], "LSMinimumSystemVersion": "13.0"}
plistlib.dump(info, open(sys.argv[1], "wb"))
PY
  (cd "$scratch/z" && ditto -c -k --keepParent GitHubPet.app "$scratch/$1.zip")
}
run() { (cd "$scratch/repo" && SIGN_UPDATE="$scratch/signer" scripts/release-appcast.sh "$@" 2>&1); }

make_zip 0.1.0-beta.4 300 "$key"
run v0.1.0-beta.4 "$scratch/0.1.0-beta.4.zip" >/dev/null || fail "beta release was refused"
appcast=$scratch/repo/updates/appcast.xml
grep -q '<sparkle:channel>beta</sparkle:channel>' "$appcast" || fail "beta item lacks the beta channel"
grep -q '<sparkle:version>300</sparkle:version>' "$appcast" || fail "sparkle:version is not the build number"
grep -q 'releases/download/v0.1.0-beta.4/0.1.0-beta.4.zip' "$appcast" || fail "enclosure is not the release asset"
grep -q 'sparkle:edSignature="dGVzdC1zaWduYXR1cmU="' "$appcast" || fail "signature missing"
grep -q 'fullReleaseNotesLink>https://github.com/christopherrbrown3/github-pet/releases/tag/v0.1.0-beta.4' "$appcast" || fail "notes link missing"

make_zip 0.1.0 400 "$key"
run v0.1.0 "$scratch/0.1.0.zip" >/dev/null || fail "stable release was refused"
[[ $(grep -c '<item>' "$appcast") == 2 ]] || fail "expected two items"
[[ $(grep -c 'sparkle:channel' "$appcast") == 2 ]] && fail "stable item must not carry a channel"
run v0.1.0 "$scratch/0.1.0.zip" >/dev/null || fail "re-running a release should replace its item"
[[ $(grep -c '<item>' "$appcast") == 2 ]] || fail "re-run duplicated the item"

make_zip 0.1.0-beta.5 100 "$key"
run v0.1.0-beta.5 "$scratch/0.1.0-beta.5.zip" >/dev/null && fail "a build number that goes backwards was accepted"
make_zip 0.1.0-beta.6 500 "AAAA"
run v0.1.0-beta.6 "$scratch/0.1.0-beta.6.zip" >/dev/null && fail "a ZIP with the wrong key was accepted"
make_zip 0.1.0-beta.7 600 "$key"
run v0.1.0-beta.8 "$scratch/0.1.0-beta.7.zip" >/dev/null && fail "a tag that disagrees with the app was accepted"
run notatag "$scratch/0.1.0.zip" >/dev/null && fail "a malformed tag was accepted"
xmllint --noout "$appcast" || fail "appcast is not valid XML"

(( failures == 0 )) && echo "release appcast checks passed" || { echo "$failures release appcast check(s) failed" >&2; exit 1; }
