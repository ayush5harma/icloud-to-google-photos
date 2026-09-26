#!/usr/bin/env bash
# The menu's model (Sources/model.swift) compiled beside test/menu.swift and
# run: which backend the dropdown describes when the collector has or has not
# answered, which ledger rows each backend shows, and the ledger's text. No
# AppKit, no menu bar, no collector; nothing outside a scratch directory.
#
# Usage: test/menu.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFTC="$(command -v swiftc 2>/dev/null || xcrun --find swiftc 2>/dev/null)"
[ -n "$SWIFTC" ] || { echo "  SKIP  swiftc not found (xcode-select --install)"; exit 0; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# Top-level code compiles only from a file named main.swift.
cp "$HERE/menu.swift" "$T/main.swift"
"$SWIFTC" -o "$T/menu" "$HERE/../Sources/model.swift" "$T/main.swift" \
  || { echo "  FAIL  the model and its test did not compile"; exit 1; }
"$T/menu"
