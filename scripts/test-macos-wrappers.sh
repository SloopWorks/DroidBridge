#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
mkdir -p verification/launcher-fix/wrappers
swiftc -parse-as-library -I "$BIN/Modules" Sources/DroidBridge/MacAppWrapper.swift scripts/test-macos-wrappers.swift "$BIN"/DroidBridgeCore.build/*.o -o .build/test-macos-wrappers
clang -dynamiclib scripts/verify-unbuffered.c -o .build/wrapper-unbuffered.dylib
DYLD_INSERT_LIBRARIES="$PWD/.build/wrapper-unbuffered.dylib" .build/test-macos-wrappers 2>&1 | tee verification/launcher-fix/wrappers/run.log
