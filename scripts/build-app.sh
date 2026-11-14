#!/bin/zsh
# Build GitHubPet.app without Xcode: compile with SwiftPM, assemble the bundle by hand,
# then ad-hoc sign it so macOS will launch it locally. Ad-hoc signed only, not notarized.
#
#   scripts/build-app.sh [debug|release] [--universal]     (default: release, host architecture)
#   output: .build/app/GitHubPet.app
#
# --universal builds arm64 and x86_64 separately (SwiftPM's multi-arch --arch needs Xcode's
# xcbuild, which the Command Line Tools lack) and merges them with lipo.
# Version: the VERSION file (CFBundleShortVersionString); build number: the commit count.
set -euo pipefail
cd "${0:A:h}/.."

configuration=release
universal=0
for argument in "$@"; do
  case "$argument" in
    debug|release) configuration=$argument ;;
    --universal) universal=1 ;;
    *) echo "usage: $0 [debug|release] [--universal]" >&2; exit 64 ;;
  esac
done

app_name=GitHubPet
bundle_id=dev.github-pet.GitHubPet
version=$(tr -d '[:space:]' < VERSION)
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "VERSION must be MAJOR.MINOR.PATCH, got '$version'" >&2; exit 65; }
# A shallow count can look valid (even >1) while silently understating the build number.
# Reject it before compiling; package verification must not compare two truncated counts.
if [[ $(git rev-parse --is-shallow-repository 2>/dev/null) != false ]]; then
  echo "build-app: requires a Git checkout with complete history; for a shallow clone, run git fetch --unshallow" >&2
  exit 65
fi
source_revision=$(git rev-parse HEAD)
build_number=$(git rev-list --count HEAD)

app=.build/app/$app_name.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if (( universal )); then
  slices=()
  for arch in arm64 x86_64; do
    triple=$arch-apple-macosx13.0
    swift build -c "$configuration" --product "$app_name" --triple "$triple"
    slices+=("$(swift build -c "$configuration" --triple "$triple" --show-bin-path)/$app_name")
  done
  lipo -create "${slices[@]}" -output "$app/Contents/MacOS/$app_name"
else
  swift build -c "$configuration" --product "$app_name"
  cp "$(swift build -c "$configuration" --show-bin-path)/$app_name" "$app/Contents/MacOS/$app_name"
fi

# Runtime mascot pack: manifest and frames only (sheets, sources and UI specs stay in the repo).
pack_id=mona-pet-v1
pack_src=assets/mascots/$pack_id
pack_dst="$app/Contents/Resources/MascotPacks/$pack_id"
mkdir -p "$pack_dst/frames"
cp "$pack_src/manifest.json" "$pack_dst/"
cp "$pack_src"/frames/*.png "$pack_dst/frames/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>GitHub Pet</string>
  <key>CFBundleExecutable</key><string>$app_name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$app_name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>GitHubPetSourceRevision</key><string>$source_revision</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GitHub Pet contributors</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
echo "Built $app $version ($build_number), $configuration, $(lipo -archs "$app/Contents/MacOS/$app_name"), ad-hoc signed"
