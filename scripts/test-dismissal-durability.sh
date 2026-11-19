#!/bin/zsh
# Compile against the actual debug store. Only a disposable hosted CI runner may use a disk suite.
set -euo pipefail
cd "${0:A:h}/.."
mode=${1:---run}
[[ "$mode" == --run || "$mode" == --build-only ]] || { echo 'expected --run or --build-only' >&2; exit 1; }
if [[ "$mode" == --run ]]; then
  [[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_OS:-}" == macOS && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
    echo 'dismissal startup persistence requires a disposable GitHub-hosted macOS runner' >&2
    exit 1
  }
fi

build=.build/debug
objects=("$build"/GitHubPetCore.build/*.swift.o(N))
(( ${#objects} > 0 )) || { echo 'completed debug GitHubPetCore build required' >&2; exit 1; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
client="$scratch/dismissal-store-client"
swiftc -I "$build/Modules" Tests/ExternalDismissalStoreClient/main.swift "${objects[@]}" -o "$client"
[[ "$mode" == --run ]] || exit 0

suite="dev.github-pet.dismissal-durability-ci.$(/usr/bin/uuidgen)"
writer_status=0
reader_status=0
"$client" write "$suite" &
writer_pid=$!
wait "$writer_pid" || writer_status=$?
"$client" verify "$suite" "$writer_pid" || reader_status=$?
echo "Dismissal startup persistence exit codes - writer $writer_status, reader $reader_status"
(( writer_status == 0 && reader_status == 0 ))
