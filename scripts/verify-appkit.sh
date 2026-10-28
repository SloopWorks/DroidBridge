#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
mkdir -p verification/review/appkit
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/NativeWindow.swift scripts/verify-appkit.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o verification/review/appkit/verify-appkit
verification/review/appkit/verify-appkit 2>&1 | tee verification/review/appkit/run.log
