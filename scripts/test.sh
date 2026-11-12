#!/bin/zsh
# Run the test suite. With only Command Line Tools installed, swift-testing ships as a
# framework that SwiftPM does not find on its own, so point the compiler and linker at it.
# The CLT copy of the Testing/Foundation cross-import overlay ships without a module, so
# cross-import overlays are disabled there (tests do not rely on it).
set -euo pipefail
cd "${0:A:h}/.."

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
