#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
# Deliberately pinned to the same API/build tools used by the test application.
BT="$SDK/build-tools/35.0.0"
ANDROID_JAR="$SDK/platforms/android-35/android.jar"
OUT="$ROOT/.build/icon-helper"
mkdir -p "$OUT/classes" "$OUT/dex"
javac -source 8 -target 8 -classpath "$ANDROID_JAR" -d "$OUT/classes" "$ROOT/android/icon-helper/dev/droidbridge/icons/IconHelper.java"
"$BT/d8" --lib "$ANDROID_JAR" --min-api 29 --output "$OUT/dex" "$OUT/classes/dev/droidbridge/icons/IconHelper.class"
# -X strips extra timestamps/UID metadata. Only our own DEX is distributed.
(cd "$OUT/dex" && /usr/bin/zip -q -X "$OUT/icon-helper.jar" classes.dex)
echo "$OUT/icon-helper.jar"
