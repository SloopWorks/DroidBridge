#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
swift build
BIN=$(swift build --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" verification/desktop-mode/VerifyDesktopNative.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/verify-desktop-native
DROIDBRIDGE_TEST_SERIAL=${DROIDBRIDGE_TEST_SERIAL:-emulator-5580} .build/verify-desktop-native
