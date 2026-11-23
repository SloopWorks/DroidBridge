#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
EVIDENCE="$PWD/verification/telemetry-2026-11-21"
eval "$(python3 - <<'PY'
import json,shlex
from pathlib import Path
s=json.loads(Path('verification/telemetry-2026-11-21/runtime-state.json').read_text())
for key,value in {'QA_SCOPE':s['scope'],'HOST_APP':s['app'],'MAIN_PID':s['main_pid'],'LOOPBACK_PORT':s['proxy_port']}.items():
 print(key+'='+shlex.quote(str(value)))
PY
)"
exec > >(tee "$EVIDENCE/appkit-runtime.log") 2>&1
swift build
BIN=$(swift build --show-bin-path)
QA_APP="$QA_SCOPE/TelemetryFixture.app"
ditto "$HOST_APP" "$QA_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable VerifyTelemetry' "$QA_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier app.droidbridge.qa.telemetry' "$QA_APP/Contents/Info.plist"
UI_SOURCES=()
while IFS= read -r source; do UI_SOURCES+=("$source"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-telemetry-appkit.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o "$BIN"/AnonymousUsage.build/*.o -o "$QA_APP/Contents/MacOS/VerifyTelemetry"
DROIDBRIDGE_GUI_EVIDENCE="$EVIDENCE" DROIDBRIDGE_TELEMETRY_HOST="$HOST_APP" DROIDBRIDGE_TELEMETRY_MAIN_PID="$MAIN_PID" "$QA_APP/Contents/MacOS/VerifyTelemetry" --companion-qa-root "$QA_SCOPE" --serial emulator-5580 --usage-loopback-port "$LOOPBACK_PORT"
