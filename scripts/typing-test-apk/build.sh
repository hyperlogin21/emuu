#!/bin/bash
# Builds emuu-typetest.apk (a text field that logs key events and its text) with the SDK's build-tools; used for the keyboard/typing tests
# (EMUU_APP_SELFTEST_ONLY=keyboard, see Sources/EmuuApp/KeyboardSelfTest.swift). Output: $OUT (default ./build/emuu-typetest.apk).
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-36/android.jar"
B=build; rm -rf "$B"; mkdir -p "$B/classes" "$B/dex"
javac --release 11 -classpath "$JAR" -d "$B/classes" src/dev/emuu/typetest/TypeActivity.java
"$BT/d8" --min-api 26 --lib "$JAR" --output "$B/dex" $(find "$B/classes" -name '*.class')
"$BT/aapt2" link -o "$B/unsigned.apk" -I "$JAR" --manifest AndroidManifest.xml
(cd "$B/dex" && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$B/unsigned.apk" "$B/aligned.apk"
keytool -genkeypair -keystore "$B/debug.ks" -storepass android -keypass android -alias k -keyalg RSA -keysize 2048 \
  -validity 365 -dname "CN=Emuu Test" >/dev/null 2>&1
OUT="${OUT:-$B/emuu-typetest.apk}"
"$BT/apksigner" sign --ks "$B/debug.ks" --ks-pass pass:android --out "$OUT" "$B/aligned.apk"
echo "$OUT"
