#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target DroidBridgeCore
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/DeviceOnboardingAgent.swift scripts/verify-availability-migration.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/qa-availability-migration
.build/qa-availability-migration "$@"
