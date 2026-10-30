#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r QA_SOURCE; do UI_SOURCES+=("$QA_SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-companion-gui.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/qa-companion-gui
DROIDBRIDGE_ADB=/usr/bin/false DROIDBRIDGE_SCRCPY=/usr/bin/false DROIDBRIDGE_SERVER=/nonexistent/droidbridge-server .build/qa-companion-gui
