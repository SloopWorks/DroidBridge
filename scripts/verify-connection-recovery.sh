#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
EVIDENCE="${DROIDBRIDGE_RECOVERY_EVIDENCE:-$PWD/verification/recovery-hardening-2026-11-07/fixture}"
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/run.log") 2>&1
QA_ROOT=$(mktemp -d /private/tmp/droidbridge-recovery.XXXXXX)
chmod 700 "$QA_ROOT"
trap 'rm -rf "$QA_ROOT"' EXIT
REAL_ADB="$PWD/dist/DroidBridge.app/Contents/Resources/Runtime/bin/adb"
printf '%s\n' 'COMMAND: swift build; swiftc shipping UI sources + real-emulator recovery fixture'
swift build
BIN=$(swift build --show-bin-path)
UI_SOURCES=()
while IFS= read -r SOURCE; do UI_SOURCES+=("$SOURCE"); done < <(rg --files Sources/DroidBridge | rg '\.swift$' | rg -v '/main\.swift$' | sort)
swiftc -parse-as-library -I "$BIN/Modules" "${UI_SOURCES[@]}" scripts/verify-connection-recovery.swift "$BIN"/DroidBridgeCore.build/*.o "$BIN"/DroidBridgeStreaming.build/*.o -o "$QA_ROOT/verify-recovery"
cat > "$QA_ROOT/adb" <<'PY'
#!/usr/bin/env python3
import os, pathlib, sys, time
root = pathlib.Path(__file__).parent
if sys.argv[1:] == ['-s', 'emulator-5580', 'shell', 'dumpsys', 'power'] and (root/'delay-power').exists():
    (root/'power-reached').touch()
    time.sleep(0.8)
os.execv(os.environ['DROIDBRIDGE_REAL_ADB'], [os.environ['DROIDBRIDGE_REAL_ADB']] + sys.argv[1:])
PY
chmod +x "$QA_ROOT/adb"
printf '%s\n' 'COMMAND: real video fixture, isolated root, only emulator-5580; exact owned server termination and scoped sleep/wake'
DROIDBRIDGE_REAL_ADB="$REAL_ADB" DROIDBRIDGE_ADB="$QA_ROOT/adb" DROIDBRIDGE_SCRCPY="$PWD/dist/DroidBridge.app/Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy" DROIDBRIDGE_SERVER="$PWD/dist/DroidBridge.app/Contents/Resources/Runtime/share/scrcpy/scrcpy-server" DROIDBRIDGE_SUPERVISOR="$PWD/.build/debug/DroidBridgeSupervisor" DROIDBRIDGE_RECOVERY_EVIDENCE="$EVIDENCE" "$QA_ROOT/verify-recovery" --companion-qa-root "$QA_ROOT" --serial emulator-5580 "$@"
