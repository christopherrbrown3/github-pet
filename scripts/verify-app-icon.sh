#!/bin/zsh
# Verify a built bundle's application icon: AppIcon.icns exists and decodes to the full ten-image
# iconset, CFBundleIconFile is AppIcon and LSUIElement is still true (menu-bar only, no Dock icon).
#
#   scripts/verify-app-icon.sh <path/to/GitHubPet.app>
set -euo pipefail
(( $# == 1 )) || { echo "usage: $0 <app>" >&2; exit 64; }
app=$1
plist=$app/Contents/Info.plist
icns=$app/Contents/Resources/AppIcon.icns
fail() { echo "verify-app-icon: $1" >&2; exit 1; }

[[ -s $icns ]] || fail "missing or empty $icns"
[[ $(head -c 4 "$icns") == icns ]] || fail "AppIcon.icns does not start with the icns magic"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
iconutil -c iconset "$icns" -o "$scratch/AppIcon.iconset" >/dev/null 2>&1 || fail "AppIcon.icns is not a valid icns"
count=$(find "$scratch/AppIcon.iconset" -name '*.png' | wc -l | tr -d ' ')
[[ $count == 10 ]] || fail "AppIcon.icns decodes to $count images, expected 10"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist" 2>/dev/null) == AppIcon ]] || fail "CFBundleIconFile is not AppIcon"
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist" 2>/dev/null) == true ]] || fail "LSUIElement is not true"
echo "PASS app icon: $icns (10 images), CFBundleIconFile=AppIcon, LSUIElement=true"
