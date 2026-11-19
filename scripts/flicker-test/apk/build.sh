#!/bin/bash
# Builds emuu-flickertest.apk (VideoActivity: MediaPlayer in SurfaceView/TextureView with UI on top; CodecActivity:
# MediaCodec driven like a short-video feed player (async, flush loops, swipes, setOutputSurface, preload, own GL);
# GLActivity: 60 fps GL pattern) with the SDK's build-tools. Output: $OUT (default ./build/emuu-flickertest.apk).
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
OUT="${OUT:-$B/emuu-flickertest.apk}"
"$BT/apksigner" sign --ks "$B/debug.ks" --ks-pass pass:android --out "$OUT" "$B/aligned.apk"
echo "$OUT"
