#!/bin/bash
# Build only. Installation must explicitly target an owned verification emulator.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
TASK_JAVA_HOME=${DROIDBRIDGE_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
BT="$SDK/build-tools/35.0.0"
OUT="$ROOT/.build/companion-fixture"
mkdir -p "$OUT/classes" "$OUT/dex"
"$BT/aapt" package -f -M "$ROOT/android/companion-fixture/AndroidManifest.xml" -I "$SDK/platforms/android-35/android.jar" -F "$OUT/unsigned.apk"
"$TASK_JAVA_HOME/bin/javac" -source 8 -target 8 -classpath "$SDK/platforms/android-35/android.jar" -d "$OUT/classes" "$ROOT"/android/companion-fixture/*.java
CLASSES=()
while IFS= read -r -d '' file; do CLASSES+=("$file"); done < <(find "$OUT/classes" -name '*.class' -print0)
JAVA_HOME="$TASK_JAVA_HOME" "$BT/d8" --lib "$SDK/platforms/android-35/android.jar" --min-api 33 --output "$OUT/dex" "${CLASSES[@]}"
(cd "$OUT/dex" && zip -q -u "$OUT/unsigned.apk" classes.dex)
if [ ! -f "$OUT/debug.jks" ]; then "$TASK_JAVA_HOME/bin/keytool" -genkeypair -keystore "$OUT/debug.jks" -storepass android -keypass android -alias androiddebugkey -dname 'CN=DroidBridge Companion Verification' -keyalg RSA -validity 3650 >/dev/null 2>&1; fi
JAVA_HOME="$TASK_JAVA_HOME" "$BT/apksigner" sign --ks "$OUT/debug.jks" --ks-pass pass:android --out "$OUT/DroidBridgeCompanionFixture.apk" "$OUT/unsigned.apk"
JAVA_HOME="$TASK_JAVA_HOME" "$BT/apksigner" verify "$OUT/DroidBridgeCompanionFixture.apk"
shasum -a 256 "$OUT/DroidBridgeCompanionFixture.apk"
