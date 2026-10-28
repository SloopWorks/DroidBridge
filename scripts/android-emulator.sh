#!/bin/bash
set -euo pipefail
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
AVD=DroidBridge_API35
if ! "$SDK/emulator/emulator" -list-avds | /usr/bin/grep -qx "$AVD"; then
 "$SDK/cmdline-tools/latest/bin/avdmanager" create avd --name "$AVD" --package 'system-images;android-35;default;arm64-v8a' --device pixel_7
fi
if "$SDK/platform-tools/adb" -s emulator-5580 get-state >/dev/null 2>&1; then
 echo 'Dedicated DroidBridge emulator already running at emulator-5580'
 exit 0
fi
mkdir -p "$ROOT/verification/android"
exec "$SDK/emulator/emulator" -avd "$AVD" -port 5580 -no-window -no-audio -no-snapshot -gpu auto
