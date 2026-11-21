#!/bin/zsh
# Compile a separate normal-import client against the completed debug module/objects.
# No build mutation; run scripts/test.sh first. This proves public API access without @testable.
set -euo pipefail
cd "${0:A:h}/.."
build=${1:-.build/debug}
objects=("$build"/GitHubPetCore.build/*.swift.o(N))
(( ${#objects} > 0 )) || { echo 'test-public-budget: completed debug core build required' >&2; exit 1; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -I "$build/Modules" Tests/ExternalBudgetClient/main.swift "${objects[@]}" -o "$scratch/external-budget-client"
"$scratch/external-budget-client"
