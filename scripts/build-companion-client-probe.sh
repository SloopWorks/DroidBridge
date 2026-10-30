#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
swift build --target DroidBridgeCore
OBJECTS=()
while IFS= read -r -d '' file; do OBJECTS+=("$file"); done < <(find .build/debug/DroidBridgeCore.build -name '*.o' -print0)
swiftc -parse-as-library -I .build/debug/Modules scripts/verify-companion-client.swift "${OBJECTS[@]}" -o .build/verify-companion-client
