#!/bin/zsh
# Run the test suite. With only Command Line Tools installed, swift-testing ships as a
# framework that SwiftPM does not find on its own, so point the compiler and linker at it.
# The CLT copy of the Testing/Foundation cross-import overlay ships without a module, so
# cross-import overlays are disabled there (tests do not rely on it).
set -euo pipefail
self=${0:A}
cd "${self:h}/.."

# The descriptor-leak check counts /dev/fd for the whole process, so any other suite running in
# parallel (children, AppKit descriptors) can flake it (#102). CI runs it alone in its own
# process; with no arguments, so does this script. With arguments (a filter, --skip-build, the
# CI steps) they pass through unchanged and the caller owns the isolation.
fd_test='\bdescendantHoldingThePipeDoesNotLeakReadsOrDescriptors\b'
if (( $# == 0 )); then
  "$self" --skip "$fd_test"
  log=$(mktemp)
  trap 'rm -f "$log"' EXIT
  "$self" --skip-build --filter "$fd_test" | tee "$log"
  # A filter that matches nothing also exits 0: require the named test to have passed, alone.
  if ! grep -Eq '^✔ Test descendantHoldingThePipeDoesNotLeakReadsOrDescriptors\(\) passed' "$log" ||
     ! grep -Eq '^✔ Test run with 1 test( in [0-9]+ suites?)? passed' "$log"; then
    echo "test.sh: the isolated descriptor test did not run and pass exactly once" >&2
    exit 1
  fi
  exit 0
fi

clt_frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
developer_dir=$(xcode-select -p 2>/dev/null || true)

if [[ "$developer_dir" == /Library/Developer/CommandLineTools && -d "$clt_frameworks/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$clt_frameworks" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$clt_frameworks" \
    -Xlinker -rpath -Xlinker "$clt_frameworks" \
    "$@"
fi
exec swift test "$@"
