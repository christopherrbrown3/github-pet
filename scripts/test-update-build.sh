#!/bin/zsh
# Regression check for the Sparkle packaging in build-app.sh (#90): the framework is embedded and
# signed inside-out, the Info.plist keys are exactly what the app expects, a default build carries
# the committed feed URL and no test key, and the build-time QA overrides behave.
# Builds the debug app twice (QA overrides first, default last); no network beyond SwiftPM's cache.
#
#   scripts/test-update-build.sh
set -euo pipefail
cd "${0:A:h}/.."

app=.build/app/GitHubPet.app
plist=$app/Contents/Info.plist
committed_feed=https://raw.githubusercontent.com/christopherrbrown3/github-pet/main/updates/appcast.xml
test_key_file=Tests/fixtures/sparkle-test-public-key.txt
test_key=$(grep -v '^#' "$test_key_file" | tr -d '[:space:]')
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
get() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
expect() { [[ $(get "$1") == "$2" ]] || fail "$1 is '$(get "$1")', expected '$2'"; }
absent() { [[ -z $(get "$1") ]] || fail "$1 should be absent, found '$(get "$1")'"; }

check_bundle() {
  [[ -d $app/Contents/Frameworks/Sparkle.framework/Versions/B ]] || fail "Sparkle.framework missing"
  [[ -L $app/Contents/Frameworks/Sparkle.framework/Sparkle ]] || fail "framework symlinks were not preserved"
  [[ ! -e $app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices ]] || fail "XPC services were not removed"
  otool -l "$app/Contents/MacOS/GitHubPet" | grep -q '@executable_path/../Frameworks' || fail "rpath to Contents/Frameworks missing"
  otool -L "$app/Contents/MacOS/GitHubPet" | grep -q '@rpath/Sparkle.framework/Versions/B/Sparkle' || fail "binary does not link Sparkle"
  local nested
  for nested in "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
                "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
                "$app/Contents/Frameworks/Sparkle.framework" "$app"; do
    codesign --verify --strict "$nested" 2>/dev/null || fail "signature invalid: $nested"
  done
  codesign --verify --strict --deep "$app" 2>/dev/null || fail "deep verification failed"
  expect SUAutomaticallyUpdate false
  expect SUAllowsAutomaticUpdates true
  expect SUScheduledCheckInterval 86400
  expect SUVerifyUpdateBeforeExtraction true
  absent SUEnableSystemProfiling
  absent SUEnableAutomaticChecks
  absent SUPublicDSAKey
}

# Bad inputs are refused before anything is compiled.
for bad in "BUNDLE_ID_SUFFIX=Bad" "BUNDLE_ID_SUFFIX=.a.b" "SPARKLE_FEED_URL=http://evil.example/appcast.xml" \
           "SPARKLE_FEED_URL=https://example.com/a.xml?x=1" "SPARKLE_PUBLIC_KEY_FILE=/nonexistent"; do
  if env "$bad" scripts/build-app.sh debug >/dev/null 2>&1; then fail "build accepted $bad"; fi
done
printf 'not a key\n' > "${TMPDIR:-/tmp}/bad-sparkle-key.txt"
if SPARKLE_PUBLIC_KEY_FILE="${TMPDIR:-/tmp}/bad-sparkle-key.txt" scripts/build-app.sh debug >/dev/null 2>&1; then fail "build accepted a malformed key"; fi
rm -f "${TMPDIR:-/tmp}/bad-sparkle-key.txt"

# QA build: isolated identity, local feed and test key, all written at build time.
BUNDLE_ID_SUFFIX=.qa SPARKLE_FEED_URL=http://127.0.0.1:8123/appcast.xml SPARKLE_PUBLIC_KEY_FILE=$test_key_file \
  RELEASE_VERSION=0.1.0-beta.9 scripts/build-app.sh debug >/dev/null
check_bundle
expect CFBundleIdentifier dev.github-pet.GitHubPet.qa
expect SUFeedURL http://127.0.0.1:8123/appcast.xml
expect SUPublicEDKey "$test_key"
expect GitHubPetReleaseVersion 0.1.0-beta.9
[[ $(get NSAppTransportSecurity:NSAllowsLocalNetworking) == true ]] || fail "local feed needs the local-network exception"

# Default build: committed feed, committed key (empty until Chris adds it), never the test key.
scripts/build-app.sh debug >/dev/null
check_bundle
expect CFBundleIdentifier dev.github-pet.GitHubPet
expect SUFeedURL "$committed_feed"
committed_key=$(grep -v '^[[:space:]]*#' updates/sparkle-public-ed-key.txt | tr -d '[:space:]' || true)
# The release key is committed: a default build must carry exactly it, and it must be a valid
# 32-byte Sparkle public key, or the app would ship with its updater disabled.
[[ -n $committed_key ]] || fail "updates/sparkle-public-ed-key.txt has no key"
[[ $(print -rn -- "$committed_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ') == 32 ]] || fail "committed key is not 32 bytes"
expect SUPublicEDKey "$committed_key"
[[ $(get SUPublicEDKey) != "$test_key" ]] || fail "default build contains the test key"
absent NSAppTransportSecurity
absent GitHubPetReleaseVersion
if grep -q "127.0.0.1" "$plist"; then fail "default build contains a local feed"; fi

(( failures == 0 )) && echo "update build checks passed" || { echo "$failures update build check(s) failed" >&2; exit 1; }
