#!/bin/bash
# Regenerate AppIcon.icns from tools/make-icon.swift.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/AppIcon.iconset"
swiftc -O -o "$STAGE/gen" "$HERE/make-icon.swift"
"$STAGE/gen" "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o "$HERE/../AppIcon.icns"
echo "wrote AppIcon.icns"
