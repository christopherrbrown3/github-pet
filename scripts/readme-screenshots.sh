#!/bin/zsh
# Regenerate the README images from a built app with the offscreen --render-snapshots renderer.
# Demo fixtures only: throwaway preferences, an executable gh trap, no network, and the app is
# never launched normally (it renders offscreen and quits).
#
#   scripts/readme-screenshots.sh path/to/GitHubPet.app [output dir] [build notes file]
#
# Output defaults to docs/screenshots/beta. A build notes file (for example the CI run, artifact and
# ZIP checksum the app came from) is copied into the provenance README.
set -euo pipefail
cd "${0:A:h}/.."

app=${1:?usage: scripts/readme-screenshots.sh path/to/GitHubPet.app [output dir]}
out=${2:-docs/screenshots/beta}
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

# README name <- renderer name. Each gets a light and a -dark variant.
selection=(
  mascot-idle      01-baseline-mascot
  mascot-attention 09-attention-static-mascot
  hover            readme-hover
  inbox            readme-inbox
  settings-scope   readme-settings-scope
  settings-general readme-settings-general
)
mkdir -p "$out"
rows=()
missing=0
for (( i = 1; i <= ${#selection}; i += 2 )); do
  name=${selection[i]} source=${selection[i+1]}
  for suffix in "" -dark; do
    from=$renders/$source$suffix.png
    if [[ ! -f $from ]]; then echo "readme-screenshots: missing $source$suffix.png" >&2; missing=$((missing + 1)); continue; fi
    cp "$from" "$out/$name$suffix.png"
    width=$(sips -g pixelWidth "$from" | awk '/pixelWidth/ {print $2}')
    height=$(sips -g pixelHeight "$from" | awk '/pixelHeight/ {print $2}')
    sha=$(shasum -a 256 "$from" | awk '{print $1}')
    rows+=("| $name$suffix.png | $source$suffix.png | ${width}×${height} | \`$sha\` |")
  done
done
(( missing == 0 )) || exit 1

cat > "$out/README.md" <<MD
# Beta README image provenance

Unmodified native offscreen renders (\`--render-snapshots\`), not live desktop screenshots or
mockups. Every inbox value is an invented Demo fixture; nothing came from GitHub.

- Source revision of the rendered app: \`$revision\`
- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Command: \`scripts/readme-screenshots.sh <GitHubPet.app> $out${notes:+ <build notes>}\`
- Renderer invocation: \`GitHubPet --defaults-suite <throwaway> --fixtures --render-snapshots <scratch>\`,
  with a gh trap (gh was not launched) and throwaway preferences.

$( [[ -n $notes ]] && { printf '## Build\n\n'; cat "$notes"; } )

## Images

| Image | Renderer output | Pixels | SHA-256 |
|---|---|---|---|
$(printf '%s\n' "${rows[@]}")

Stills only: they do not show live pointer interaction, desktop placement, popover arrows or
animation. Regenerate with the command above when the UI changes.
MD
echo "readme-screenshots: wrote $(( ${#rows} )) images and README.md to $out (revision $revision)"
