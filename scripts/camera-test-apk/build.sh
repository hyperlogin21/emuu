#!/bin/bash
# Builds emuu-cameratest.apk (CameraActivity: Camera2 preview + newest frame as JPEG in files/latest.jpg, see
# src/dev/emuu/cameratest/CameraActivity.java) with the SDK build-tools, no Gradle. Output: $OUT (default ./build/emuu-cameratest.apk).
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-36/android.jar"
B=build; rm -rf "$B/classes" "$B/dex" "$B"/*.apk; mkdir -p "$B/classes" "$B/dex"   # keeps debug.ks: same signature on reinstall
javac --release 11 -classpath "$JAR" -d "$B/classes" $(find src -name '*.java')
"$BT/d8" --min-api 26 --lib "$JAR" --output "$B/dex" $(find "$B/classes" -name '*.class')
"$BT/aapt2" link -o "$B/unsigned.apk" -I "$JAR" --manifest AndroidManifest.xml
(cd "$B/dex" && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$B/unsigned.apk" "$B/aligned.apk"
[ -f "$B/debug.ks" ] || keytool -genkeypair -keystore "$B/debug.ks" -storepass android -keypass android -alias k -keyalg RSA -keysize 2048 \
  -validity 365 -dname "CN=Emuu Test" >/dev/null 2>&1
OUT="${OUT:-$B/emuu-cameratest.apk}"
"$BT/apksigner" sign --ks "$B/debug.ks" --ks-pass pass:android --out "$OUT" "$B/aligned.apk"
echo "$OUT"
