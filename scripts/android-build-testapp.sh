#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
BT="$SDK/build-tools/35.0.0"
PACKAGE="${DROIDBRIDGE_TEST_PACKAGE:-dev.droidbridge.testapp}"
[[ "$PACKAGE" =~ ^dev\.droidbridge\.testapp[0-9]*$ ]] || { echo 'Invalid test package' >&2; exit 1; }
OUT="$ROOT/verification/android/${PACKAGE##*.}"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/source"
sed "s/dev.droidbridge.testapp/$PACKAGE/g" "$ROOT/scripts/android-testapp/AndroidManifest.xml" > "$OUT/source/AndroidManifest.xml"
for file in "$ROOT"/scripts/android-testapp/*.java; do
 sed "s/dev.droidbridge.testapp/$PACKAGE/g" "$file" > "$OUT/source/$(basename "$file")"
done
"$BT/aapt" package -f -M "$OUT/source/AndroidManifest.xml" -I "$SDK/platforms/android-35/android.jar" -F "$OUT/unsigned.apk"
javac -source 8 -target 8 -classpath "$SDK/platforms/android-35/android.jar" -d "$OUT/classes" "$OUT"/source/*.java
CLASSES=()
while IFS= read -r -d '' file; do CLASSES+=("$file"); done < <(find "$OUT/classes" -name '*.class' -print0)
"$BT/d8" --lib "$SDK/platforms/android-35/android.jar" --min-api 29 --output "$OUT/dex" "${CLASSES[@]}"
(cd "$OUT/dex" && zip -q -u "$OUT/unsigned.apk" classes.dex)
if [ ! -f "$OUT/debug.jks" ]; then keytool -genkeypair -keystore "$OUT/debug.jks" -storepass android -keypass android -alias androiddebugkey -dname 'CN=DroidBridge Test' -keyalg RSA -validity 3650 >/dev/null 2>&1; fi
"$BT/apksigner" sign --ks "$OUT/debug.jks" --ks-pass pass:android --out "$OUT/DroidBridgeTest.apk" "$OUT/unsigned.apk"
"$SDK/platform-tools/adb" -s "${DROIDBRIDGE_TEST_SERIAL:-emulator-5580}" install -r "$OUT/DroidBridgeTest.apk"
