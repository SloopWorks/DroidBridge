#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product DroidBridgeCompanionBroker
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" scripts/verify-adb-helper-portability.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/qa-adb-helper-portability
.build/qa-adb-helper-portability "$@"
