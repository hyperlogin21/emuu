#!/bin/bash
# Builds EmuuApp in release mode and assembles dist/Emuu.app (Info.plist, generated icon, ad-hoc signature).
#
#   scripts/make-app.sh                # build + bundle
#   SCRATCH=.build-foo scripts/make-app.sh   # use another SwiftPM scratch dir (default .build-app)
#   SKIP_BUILD=1 scripts/make-app.sh   # re-bundle the last release build
#   DIST=/path scripts/make-app.sh     # assemble into /path/Emuu.app instead of dist/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRATCH="${SCRATCH:-.build-app}"
DIST="${DIST:-$ROOT/dist}"   # DIST=/tmp/x scripts/make-app.sh assembles elsewhere (e.g. while dist/Emuu.app is running)
APP="$DIST/Emuu.app"
VERSION="$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/EmuuBase/Emuu.swift | head -1)"
VERSION="${VERSION:-0.1.0}"
BUILD="$(date +%Y%m%d%H%M)"

if [[ -z "${SKIP_BUILD:-}" ]]; then
  echo "==> swift build -c release --product EmuuApp (scratch $SCRATCH)"
  swift build -c release --product EmuuApp --scratch-path "$SCRATCH"
fi
BIN_DIR="$(swift build -c release --product EmuuApp --scratch-path "$SCRATCH" --show-bin-path)"
BIN="$BIN_DIR/EmuuApp"
[[ -x "$BIN" ]] || { echo "error: $BIN not found" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Emuu"
strip -x "$APP/Contents/MacOS/Emuu" 2>/dev/null || true
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM resource bundles (Emuu_EmuuApp.bundle: control-strip SVG icons). They go to Contents/Resources, where
# IconLibrary looks first; Bundle.module is not used because it only searches the app root.
for b in "$BIN_DIR"/*.bundle; do [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"; done

echo "==> generating icon"
ICONWORK="$(mktemp -d)"
trap 'rm -rf "$ICONWORK"' EXIT
swift Resources/make-icon.swift "$ICONWORK/icon-1024.png" >/dev/null
ICONSET="$ICONWORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  px="${spec%%:*}"; name="${spec#*:}"
  sips -z "$px" "$px" "$ICONWORK/icon-1024.png" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "==> done: $APP ($SIZE, version $VERSION build $BUILD)"
