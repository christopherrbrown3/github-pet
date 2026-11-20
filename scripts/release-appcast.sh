#!/bin/zsh
# Run by a human on Chris's Mac when cutting a release (#90). Signs the release ZIP with Sparkle's
# sign_update (the private key stays in the login Keychain; it is never read, exported or passed
# in) and adds or replaces the matching item in updates/appcast.xml. Creates no release or tag
# and pushes nothing: upload the ZIP to the GitHub Release, then commit and push appcast.xml.
#
#   scripts/release-appcast.sh <tag> <GitHubPet-...-universal.zip>
#   e.g. scripts/release-appcast.sh v0.1.0-beta.4 .build/dist/GitHubPet-0.1.0-abc1234-universal.zip
#
# The ZIP must come from a build made with RELEASE_VERSION=<tag without v> (docs/updates.md) and
# the committed public key, so the app, tag and key all agree. SIGN_UPDATE overrides the signer (tests).
set -euo pipefail
cd "${0:A:h}/.."

(( $# == 2 )) || { echo "usage: $0 <tag> <zip>" >&2; exit 64; }
tag=$1 zip=$2
repo=christopherrbrown3/github-pet
appcast=${APPCAST:-updates/appcast.xml}
[[ $tag =~ '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ]] || { echo "tag must look like v0.1.0 or v0.1.0-beta.4, got '$tag'" >&2; exit 65; }
[[ -f $zip && $zip == *.zip ]] || { echo "not a ZIP: $zip" >&2; exit 65; }
release_version=${tag#v}

# The app inside must be the release it claims to be, signed for the committed key.
info=$(unzip -p "$zip" 'GitHubPet.app/Contents/Info.plist' | plutil -convert json -o - -) \
  || { echo "cannot read GitHubPet.app/Contents/Info.plist from $zip" >&2; exit 65; }
field() { print -r -- "$info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }
[[ $(field GitHubPetReleaseVersion) == "$release_version" ]] \
  || { echo "the app in the ZIP says release version '$(field GitHubPetReleaseVersion)', not $release_version (build with RELEASE_VERSION=$release_version)" >&2; exit 65; }
committed_key=$(grep -v '^[[:space:]]*#' updates/sparkle-public-ed-key.txt | tr -d '[:space:]' || true)
[[ -n $committed_key ]] || { echo "updates/sparkle-public-ed-key.txt is empty; do the one-time key setup first" >&2; exit 65; }
[[ $(field SUPublicEDKey) == "$committed_key" ]] \
  || { echo "the app's SUPublicEDKey is not the committed key; rebuild with the committed key" >&2; exit 65; }
build=$(field CFBundleVersion)
[[ $build =~ '^[0-9]+$' ]] || { echo "CFBundleVersion '$build' is not a build number" >&2; exit 65; }

signer=${SIGN_UPDATE:-.build/artifacts/sparkle/Sparkle/bin/sign_update}
[[ -x $signer ]] || { echo "sign_update not found at $signer; run swift package resolve" >&2; exit 65; }
signature=$("$signer" "$zip") || { echo "sign_update failed; is the Sparkle key in the login Keychain?" >&2; exit 1; }
[[ $signature =~ '^sparkle:edSignature="[A-Za-z0-9+/=]+" length="[0-9]+"$' ]] \
  || { echo "unexpected sign_update output: $signature" >&2; exit 1; }

python3 - "$appcast" "$tag" "$release_version" "$build" "$(basename "$zip")" "$signature" "$repo" "$(field LSMinimumSystemVersion)" <<'PY'
import re, sys, email.utils
import xml.etree.ElementTree as ET
path, tag, version, build, name, signature, repo, minimum = sys.argv[1:]
SP = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SP)
q = lambda n: "{%s}%s" % (SP, n)
tree = ET.parse(path)
channel = tree.getroot().find("channel")
items = channel.findall("item")
for item in items:
    if item.findtext(q("shortVersionString")) == version:
        channel.remove(item)
others = [int(i.findtext(q("version"), "0")) for i in channel.findall("item")]
if others and int(build) <= max(others):
    sys.exit("build %s is not newer than the highest build in the appcast (%d); Sparkle compares sparkle:version" % (build, max(others)))
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = "GitHub Pet " + version
ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
ET.SubElement(item, q("version")).text = build
ET.SubElement(item, q("shortVersionString")).text = version
ET.SubElement(item, q("minimumSystemVersion")).text = minimum or "13.0"
if "-" in version:
    ET.SubElement(item, q("channel")).text = "beta"
ET.SubElement(item, q("fullReleaseNotesLink")).text = "https://github.com/%s/releases/tag/%s" % (repo, tag)
enclosure = ET.SubElement(item, "enclosure", {
    "url": "https://github.com/%s/releases/download/%s/%s" % (repo, tag, name),
    "type": "application/octet-stream"})
for key, value in re.findall(r'([\w:]+)="([^"]*)"', signature):
    enclosure.set(q(key.split(":")[1]) if key.startswith("sparkle:") else key, value)
ET.indent(tree, space="    ")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
xmllint --noout "$appcast"
echo "Signed $zip and updated $appcast for $tag (build $build). Review the diff, upload the ZIP to the release, then commit and push the appcast."
