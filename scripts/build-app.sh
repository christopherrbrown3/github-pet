#!/bin/zsh
# Build GitHubPet.app without Xcode: compile with SwiftPM, assemble the bundle by hand,
# then ad-hoc sign it so macOS will launch it locally. Not notarized; not for distribution.
#
#   scripts/build-app.sh [debug|release]     (default: release)
#   output: .build/app/GitHubPet.app
set -euo pipefail
cd "${0:A:h}/.."

configuration=${1:-release}
case "$configuration" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 64 ;; esac

app_name=GitHubPet
bundle_id=dev.github-pet.GitHubPet
version=0.1.0
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c "$configuration" --product "$app_name"
bin_dir=$(swift build -c "$configuration" --show-bin-path)

app=.build/app/$app_name.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/$app_name" "$app/Contents/MacOS/$app_name"

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
echo "Built $app ($configuration, ad-hoc signed)"
