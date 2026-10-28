#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"
BT="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-35/android.jar"
OUT="$ROOT/.build/icon-helper/fixture"
SOURCE="$ROOT/android/icon-helper/fixture"
mkdir -p "$OUT/classes" "$OUT/dex"
"$BT/aapt2" compile --dir "$SOURCE/res" -o "$OUT/resources.zip"
"$BT/aapt2" link -o "$OUT/unsigned.apk" --manifest "$SOURCE/AndroidManifest.xml" -I "$PLATFORM" "$OUT/resources.zip"
javac -source 8 -target 8 -classpath "$PLATFORM" -d "$OUT/classes" "$SOURCE/MainActivity.java"
"$BT/d8" --lib "$PLATFORM" --min-api 29 --output "$OUT/dex" "$OUT/classes/dev/droidbridge/iconfixture/MainActivity.class"
(cd "$OUT/dex" && /usr/bin/zip -q -u "$OUT/unsigned.apk" classes.dex)
if [ ! -f "$OUT/debug.jks" ]; then keytool -genkeypair -keystore "$OUT/debug.jks" -storepass android -keypass android -alias androiddebugkey -dname 'CN=DroidBridge Icon Test' -keyalg RSA -validity 3650 >/dev/null 2>&1; fi
"$BT/apksigner" sign --ks "$OUT/debug.jks" --ks-pass pass:android --out "$OUT/IconFixture.apk" "$OUT/unsigned.apk"
"$SDK/platform-tools/adb" -s "${DROIDBRIDGE_TEST_SERIAL:-emulator-5580}" install -r "$OUT/IconFixture.apk"
