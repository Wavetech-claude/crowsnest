#!/bin/bash
# Compiles and runs the offline tests: the Notifier decision logic, and the
# panel's colour contrast. Dependency-free by design: no XCTest, no SwiftPM
# package (there isn't one in this repo).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/../Sources"
BIN="$(mktemp -t crowsnest-notifier-tests)"
CONTRAST_BIN="$(mktemp -t crowsnest-contrast-tests)"
trap 'rm -f "$BIN" "$CONTRAST_BIN"' EXIT

swiftc -parse-as-library -target arm64-apple-macos14.0 \
    -o "$BIN" \
    "$SRC/Session.swift" "$SRC/Notifier.swift" "$HERE/NotifierTests.swift"

"$BIN"

# The contrast check only covers colours that come from Palette.swift, so the
# panel may not take any from elsewhere.
if grep -nE '\.(primary|secondary|tertiary|quaternary)\b|Color\.(orange|yellow|green|red|gray|blue|white|black)\b' \
        "$SRC/MenuPanel.swift"; then
    echo "FAIL - MenuPanel.swift uses a colour outside Palette.swift (lines above); add it to Palette and ContrastTests"
    exit 1
fi

swiftc -parse-as-library -target arm64-apple-macos14.0 \
    -o "$CONTRAST_BIN" \
    "$SRC/Session.swift" "$SRC/Palette.swift" "$HERE/ContrastTests.swift"

"$CONTRAST_BIN"
