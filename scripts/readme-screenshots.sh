#!/bin/zsh
# Regenerate the README images from a built app with the offscreen --render-snapshots renderer.
# Demo fixtures only: throwaway preferences, an executable gh trap, no network, and the app is
# never launched normally (it renders offscreen and quits). Each render is then framed
# (scripts/readme-frame.swift) and losslessly recompressed (scripts/png-optimize.py).
#
#   scripts/readme-screenshots.sh path/to/GitHubPet.app [output dir] [build notes file]
#
# Output defaults to docs/screenshots/beta-4. A build notes file (for example the CI run, artifact
# and ZIP checksum the app came from) is copied into the provenance README.
set -euo pipefail
cd "${0:A:h}/.."

app=${1:?usage: scripts/readme-screenshots.sh path/to/GitHubPet.app [output dir]}
out=${2:-docs/screenshots/beta-4}
notes=${3:-}
[[ -z $notes || -f $notes ]] || { echo "readme-screenshots: no build notes file at $notes" >&2; exit 1; }
binary=$app/Contents/MacOS/GitHubPet
[[ -x $binary ]] || { echo "readme-screenshots: no executable at $binary" >&2; exit 1; }
revision=$(/usr/libexec/PlistBuddy -c 'Print :GitHubPetSourceRevision' "$app/Contents/Info.plist" 2>/dev/null || echo unknown)

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
renders=$scratch/renders
# An absolute-path preferences domain inside the scratch directory: the app's real domain and
# ~/Library/Preferences are never touched (see render-check.sh).
suite=$scratch/throwaway-preferences
cat > "$scratch/gh" <<'GH'
#!/bin/sh
printf 'unexpected gh invocation\n' >> "$GITHUB_PET_SNAPSHOT_GH_TRAP"
exit 99
GH
chmod +x "$scratch/gh"

command=("$binary" --defaults-suite "$suite" --fixtures --render-snapshots "$renders")
GITHUB_PET_GH_PATH="$scratch/gh" GITHUB_PET_SNAPSHOT_GH_TRAP="$scratch/gh-called" "${command[@]}" &
pid=$!
# A debug build takes about 4.5 minutes; the bound only stops a hung renderer.
for _ in {1..600}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
if kill -0 $pid 2>/dev/null; then kill $pid; echo "readme-screenshots: renderer timed out" >&2; exit 1; fi
wait $pid || true
[[ -f $renders/report.txt ]] || { echo "readme-screenshots: renderer produced no report" >&2; exit 1; }
[[ ! -e $scratch/gh-called ]] || { echo "readme-screenshots: the renderer launched gh" >&2; exit 1; }
grep -q 'source=fixtures' "$renders/report.txt" || { echo "readme-screenshots: not a Demo fixture render" >&2; exit 1; }

# README name <- renderer name, frame. Each gets a light and a -dark variant.
#   window: rounded corners, hairline and shadow; "+footer" also crops the Inbox's update/quit
#           footer, which offscreen reads "Updates not configured" (snapshot mode never starts
#           the updater). plain: the transparent mascot panel, unchanged.
selection=(
  hero-inbox          inbox87-mona-pet-v1-four        window+footer
  inbox-dismissed     inbox87-little-chris-v1-dismissed window+footer
  inbox-stale         inbox87-mona-pet-v1-stale       window+footer
  mascot-mona         readme-mascot-mona-pet-v1       plain
  mascot-little-chris readme-mascot-little-chris-v1   plain
  settings-mascot     readme-settings-mascot          window
  settings-github     readme-settings-github          window
)
mkdir -p "${out:?}"
# Replace only this set's own files, by explicit name; nothing else in $out is touched.
for (( i = 1; i <= ${#selection}; i += 3 )); do
  rm -f -- "$out/${selection[i]}.png" "$out/${selection[i]}-dark.png"
done
rows=()
missing=0
for (( i = 1; i <= ${#selection}; i += 3 )); do
  name=${selection[i]} source=${selection[i+1]} frame=${selection[i+2]}
  for suffix in "" -dark; do
    from=$renders/$source$suffix.png
    if [[ ! -f $from ]]; then echo "readme-screenshots: missing $source$suffix.png" >&2; missing=$((missing + 1)); continue; fi
    to=$out/$name$suffix.png
    crop_arg=()
    [[ $frame == *+footer ]] && crop_arg=(footer)
    crop=$(swift scripts/readme-frame.swift "$from" "$to" ${frame%+footer} "${crop_arg[@]}")
    python3 -I scripts/png-optimize.py "$to" > /dev/null
    width=$(sips -g pixelWidth "$to" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$to" | awk '/pixelHeight/ {print $2}')
    sha=$(shasum -a 256 "$from" | awk '{print $1}')
    rows+=("| $name$suffix.png | $source$suffix.png | ${frame} ${crop:+($crop)} | ${width}×${height} | \`$sha\` |")
  done
done
(( missing == 0 )) || exit 1

cat > "$out/README.md" <<MD
# Beta 4 README image provenance

Native offscreen renders (\`--render-snapshots\`) of the real SwiftUI views, not live desktop
screenshots or mockups. Every Inbox value is an invented Demo fixture; nothing came from GitHub.
Rendered at @2x (144 dpi). Framing only adds rounded corners, a hairline and a shadow outside the
rendered pixels; \`+footer\` crops the Inbox below its last divider, removing the update and quit
row (offscreen it reads "Updates not configured" because snapshot mode never starts the updater;
the shipped app shows Check for Updates… there). Kept pixels are unchanged and the PNGs are
recompressed losslessly.

The Settings images are the Mascot and GitHub panes' content: the Mascot | GitHub tab strip
doesn't draw offscreen, so it is left out rather than painted in. Each pane is rendered at a height
that ends between sections (the whole Mascot pane; the GitHub pane through Monitoring scope, as a
window that size shows it before scrolling). Open at login shows what ad-hoc-signed builds read
(unavailable, with the Login Items button). Offscreen windows are never key, so switches that are
on draw grey rather than in the accent colour.

- Data source: Demo (offline fixtures, `--fixtures`); no GitHub account or network.
- Source revision of the rendered app: \`$revision\`
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Command: \`scripts/readme-screenshots.sh <GitHubPet.app> $out${notes:+ <build notes>}\`
- Renderer invocation: \`GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>\`,
  with a gh trap (gh was not launched) and throwaway preferences.

$( [[ -n $notes ]] && { printf '## Build\n\n'; cat "$notes"; } )

## Images

| Image | Renderer output | Frame | Pixels | Renderer output SHA-256 |
|---|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
MD
echo "readme-screenshots: wrote $(( ${#rows} )) images and README.md to $out (revision $revision)"
