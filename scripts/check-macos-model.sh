#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product FlowChecks
BIN_DIR="$(swift build --show-bin-path)"
if [[ -f "$BIN_DIR/FlowCore.o" ]]; then
    CORE_OBJECTS=("$BIN_DIR/FlowCore.o")
else
    CORE_OBJECTS=("$BIN_DIR"/FlowCore.build/*.o)
fi
swiftc -parse-as-library -I "$BIN_DIR/Modules" -I "$BIN_DIR" \
    Sources/Flow/AppModel.swift Tests/FlowAppChecks/ModelChecks.swift \
    "${CORE_OBJECTS[@]}" -o "$BIN_DIR/FlowAppChecks"
"$BIN_DIR/FlowAppChecks"
