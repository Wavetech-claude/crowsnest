#!/bin/bash
# Compiles and runs the offline Notifier decision-logic tests. Dependency-free
# by design: no XCTest, no SwiftPM package (there isn't one in this repo).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(mktemp -t crowsnest-notifier-tests)"
trap 'rm -f "$BIN"' EXIT

swiftc -parse-as-library -target arm64-apple-macos14.0 \
    -o "$BIN" \
    "$HERE/../Sources/Session.swift" "$HERE/../Sources/Notifier.swift" "$HERE/NotifierTests.swift"

"$BIN"
