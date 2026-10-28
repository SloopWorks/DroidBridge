#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
mkdir -p verification/onboarding
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/MacAppWrapper.swift scripts/verify-managed-apps.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/verify-managed-apps
.build/verify-managed-apps 2>&1 | tee verification/onboarding/managed-apps.log
