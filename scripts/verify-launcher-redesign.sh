#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
QA_ROOT=$(mktemp -d /tmp/droidbridge-launcher-redesign.XXXXXX)
QA_STATE="$HOME/Library/Application Support/DroidBridge/sessions.json"
if [ -f "$QA_STATE" ]; then cp -p "$QA_STATE" "$QA_ROOT/prior-state"; fi
cleanup() {
  if [ -f "$QA_ROOT/prior-state" ]; then cp -p "$QA_ROOT/prior-state" "$QA_STATE"; else rm -f "$QA_STATE"; fi
  rm -rf "$QA_ROOT"
}
trap cleanup EXIT
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r QA_SOURCE; do UI_SOURCES+=("$QA_SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
python3 - "$QA_ROOT/AppDelegate.swift" <<'PY_EXTRACT'
from pathlib import Path
import sys
source=Path('Sources/DroidBridge/main.swift').read_text()
prefix,separator,_=source.partition('\nMainActor.assumeIsolated {')
assert separator, 'AppDelegate boundary moved; update the explicit test extraction'
Path(sys.argv[1]).write_text(prefix+'\n')
PY_EXTRACT
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" "$QA_ROOT/AppDelegate.swift" scripts/verify-launcher-redesign.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o .build/qa-launcher-redesign
mkdir -p verification/launcher-redesign/qa
rm -f verification/launcher-redesign/qa/results.json
DROIDBRIDGE_ADB=/usr/bin/false DROIDBRIDGE_SCRCPY=/usr/bin/false DROIDBRIDGE_SERVER="$QA_ROOT/nonexistent-server" .build/qa-launcher-redesign 2>&1 | tee verification/launcher-redesign/qa/run.log
rg -q '^PASS: launcher redesign' verification/launcher-redesign/qa/run.log
