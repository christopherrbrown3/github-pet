#!/bin/zsh
# Package GitHubPet.app as a downloadable ZIP with a SHA-256 checksum, then verify the archive.
# Ad-hoc signed and not notarized (no paid Apple Developer account): see docs/install.md for the
# first-launch steps. No release or tag is created; CI uploads the result as an Actions artifact.
#
#   scripts/package-zip.sh [--host-arch]     (default: universal arm64 + x86_64)
#   output: .build/dist/GitHubPet-<version>-<shortsha>-<arch>.zip and .zip.sha256
set -euo pipefail
cd "${0:A:h}/.."

universal=1
for argument in "$@"; do
  case "$argument" in
    --host-arch) universal=0 ;;
    *) echo "usage: $0 [--host-arch]" >&2; exit 64 ;;
  esac
done

if (( universal )); then scripts/build-app.sh release --universal; else scripts/build-app.sh release; fi

app=.build/app/GitHubPet.app
binary=$app/Contents/MacOS/GitHubPet
version=$(tr -d '[:space:]' < VERSION)
short_sha=$(git rev-parse --short HEAD)
archs=$(lipo -archs "$binary")
case "$archs" in
  *arm64*x86_64*|*x86_64*arm64*) arch_label=universal ;;
  *) arch_label=${archs// /-} ;;
esac

dist=.build/dist
name=GitHubPet-$version-$short_sha-$arch_label
zip=$dist/$name.zip
mkdir -p "$dist"
rm -f "$zip" "$zip.sha256"
# --keepParent keeps GitHubPet.app as the top-level item; --sequesterRsrc stores extended
# attributes and resource forks the way Finder's Compress does.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(cd "$dist" && shasum -a 256 "$name.zip" > "$name.zip.sha256")

# Self-verify: the checksum matches, and the unpacked app is intact, signed and complete.
(cd "$dist" && shasum -a 256 -c "$name.zip.sha256" >/dev/null)
check=$(mktemp -d)
trap 'rm -rf "$check"' EXIT
ditto -x -k "$zip" "$check"
unpacked=$check/GitHubPet.app
codesign --verify --strict "$unpacked"
plist=$unpacked/Contents/Info.plist
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$(git rev-list --count HEAD)"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = true
test "$(lipo -archs "$unpacked/Contents/MacOS/GitHubPet")" = "$archs"
test -f "$unpacked/Contents/Resources/MascotPacks/mona-pet-v1/manifest.json"
test "$(ls "$unpacked"/Contents/Resources/MascotPacks/mona-pet-v1/frames/*.png | wc -l)" -eq 12

echo "Packaged $zip"
echo "  architectures: $archs"
echo "  size: $(stat -f %z "$zip") bytes"
echo "  sha256: $(cut -d' ' -f1 < "$zip.sha256")"
