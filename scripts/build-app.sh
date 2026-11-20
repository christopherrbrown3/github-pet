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
# Build-time only overrides, for QA builds that must not touch the real app's preferences or feed
# (docs/updates.md). Shipped builds use the defaults; the app has no runtime override.
#   BUNDLE_ID_SUFFIX=.qa            -> dev.github-pet.GitHubPet.qa (own defaults domain and login item)
#   SPARKLE_FEED_URL=<url>          -> SUFeedURL (https, or http on 127.0.0.1/localhost)
#   SPARKLE_PUBLIC_KEY_FILE=<file>  -> SUPublicEDKey (a Sparkle public EdDSA key)
bundle_suffix=${BUNDLE_ID_SUFFIX:-}
[[ -z $bundle_suffix || $bundle_suffix =~ '^\.[a-z][a-z0-9-]{0,19}$' ]] \
  || { echo "BUNDLE_ID_SUFFIX must look like .qa, got '$bundle_suffix'" >&2; exit 65; }
bundle_id=dev.github-pet.GitHubPet$bundle_suffix
feed_url=${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/christopherrbrown3/github-pet/main/updates/appcast.xml}
[[ $feed_url =~ '^(https://|http://(127\.0\.0\.1|localhost)(:[0-9]+)?/)[A-Za-z0-9:/._~-]+$' ]] \
  || { echo "SPARKLE_FEED_URL must be https (or http on 127.0.0.1/localhost) with no query, got '$feed_url'" >&2; exit 65; }
key_file=${SPARKLE_PUBLIC_KEY_FILE:-updates/sparkle-public-ed-key.txt}
[[ -f $key_file ]] || { echo "Sparkle public key file not found: $key_file" >&2; exit 65; }
# The key file holds the public key only, optionally with # comment lines. Empty means "not
# configured": the build omits SUPublicEDKey and the app disables its updater.
public_key=$(grep -v '^[[:space:]]*#' "$key_file" | tr -d '[:space:]' || true)
if [[ -n $public_key ]]; then
  [[ $public_key =~ '^[A-Za-z0-9+/]{43}=$' ]] \
    || { echo "$key_file is not a Sparkle public EdDSA key (44 base64 characters)" >&2; exit 65; }
  sparkle_key_plist="<key>SUPublicEDKey</key><string>$public_key</string>"
else
  sparkle_key_plist=""
fi
# A local feed over http needs App Transport Security's local-network exception; https feeds don't.
ats_plist=""
[[ $feed_url == http://* ]] && ats_plist="<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>"
version=$(tr -d '[:space:]' < VERSION)
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "VERSION must be MAJOR.MINOR.PATCH, got '$version'" >&2; exit 65; }
# Optional: the release's full version (RELEASE_VERSION=0.1.0-beta.4) lets the app know its own
# prerelease and channel for update checks. It must extend VERSION; absent for local and CI builds.
release_version=${RELEASE_VERSION:-}
release_version=${release_version#v}
if [[ -n $release_version ]]; then
  [[ $release_version == $version || $release_version =~ "^${version//./\\.}-[0-9A-Za-z.-]+\$" ]] \
    || { echo "RELEASE_VERSION must be $version or $version-<prerelease>, got '$release_version'" >&2; exit 65; }
  release_plist="<key>GitHubPetReleaseVersion</key><string>$release_version</string>"
else
  release_plist=""
fi
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
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
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

# Sparkle (#90): copy the universal framework from SwiftPM's binary artifact with its symlinks
# intact, drop the XPC services (only sandboxed apps use them) and point the binary at Frameworks.
sparkle_source=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
[[ -d $sparkle_source ]] || { echo "build-app: $sparkle_source is missing; run swift package resolve" >&2; exit 65; }
sparkle=$app/Contents/Frameworks/Sparkle.framework
ditto "$sparkle_source" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
otool -l "$app/Contents/MacOS/$app_name" | grep -q '@executable_path/../Frameworks' \
  || install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$app_name"

# Stage the built-in packs' manifests and referenced runtime frames.
python3 scripts/mascot-resources.py stage assets/mascots "$app/Contents/Resources/MascotPacks"

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
  $release_plist
  <key>SUFeedURL</key><string>$feed_url</string>
  $sparkle_key_plist
  <key>SUAllowsAutomaticUpdates</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  $ats_plist
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GitHub Pet contributors</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

# Ad-hoc sign nested code inside-out, then the app itself (never --deep when signing).
for nested in "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
  codesign --force --sign - --timestamp=none "$nested"
  codesign --verify --strict "$nested"
done
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict --deep "$app"
echo "Built $app $version ($build_number), $configuration, $(lipo -archs "$app/Contents/MacOS/$app_name"), ad-hoc signed"
