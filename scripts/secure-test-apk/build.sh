#!/bin/bash
# Builds emuu-securetest.apk (a FLAG_SECURE activity) with the SDK's build-tools; used for the secure-display
# evidence (docs/evidence/secure-window-*.png). Output: $OUT (default ./build/emuu-securetest.apk).
set -euo pipefail
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -1)"
JAR="$SDK/platforms/android-36/android.jar"
B=build; rm -rf "$B"; mkdir -p "$B/classes" "$B/dex"
javac --release 11 -classpath "$JAR" -d "$B/classes" src/dev/emuu/securetest/SecureActivity.java
"$BT/d8" --min-api 26 --lib "$JAR" --output "$B/dex" $(find "$B/classes" -name '*.class')
"$BT/aapt2" link -o "$B/unsigned.apk" -I "$JAR" --manifest AndroidManifest.xml
(cd "$B/dex" && zip -q ../unsigned.apk classes.dex)
"$BT/zipalign" -f 4 "$B/unsigned.apk" "$B/aligned.apk"
keytool -genkeypair -keystore "$B/debug.ks" -storepass android -keypass android -alias k -keyalg RSA -keysize 2048 \
  -validity 365 -dname "CN=Emuu Test" >/dev/null 2>&1
OUT="${OUT:-$B/emuu-securetest.apk}"
"$BT/apksigner" sign --ks "$B/debug.ks" --ks-pass pass:android --out "$OUT" "$B/aligned.apk"
echo "$OUT"
