#!/bin/bash
# Builds the `emuu` CLI in release mode and installs it to ~/.local/bin (or $PREFIX/bin).
#
#   scripts/install.sh               # build + install to ~/.local/bin/emuu
#   PREFIX=/opt/emuu scripts/install.sh
#   SCRATCH=.build-foo scripts/install.sh   # SwiftPM scratch dir (default .build-release)
#   scripts/install.sh --uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
SCRATCH="${SCRATCH:-.build-release}"
TARGET="$BIN_DIR/emuu"

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$TARGET"
  echo "Removed $TARGET (your instances in ~/.emuu are untouched; delete them with 'emuu delete' first if you want)."
  exit 0
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: Emuu supports Apple Silicon (arm64) Macs only." >&2
  exit 1
fi
command -v swift >/dev/null || { echo "error: swift not found; install Xcode or the Xcode Command Line Tools." >&2; exit 1; }

cd "$ROOT"
echo "==> swift build -c release --product emuu (scratch $SCRATCH)"
swift build -c release --product emuu --scratch-path "$SCRATCH"
BUILT="$(swift build -c release --product emuu --scratch-path "$SCRATCH" --show-bin-path)/emuu"
[[ -x "$BUILT" ]] || { echo "error: $BUILT not found" >&2; exit 1; }

mkdir -p "$BIN_DIR"
# Copy to a temp name and rename, so a running `emuu` (e.g. a supervisor) keeps its old inode.
cp "$BUILT" "$TARGET.tmp.$$"
strip -x "$TARGET.tmp.$$" 2>/dev/null || true
# strip invalidates the linker's ad-hoc signature; re-sign so Apple Silicon will run it.
codesign --force --sign - "$TARGET.tmp.$$" >/dev/null 2>&1 || true
mv -f "$TARGET.tmp.$$" "$TARGET"
echo "==> installed $TARGET ($(du -h "$TARGET" | cut -f1 | tr -d ' '))"
"$TARGET" --version

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH. Add this to ~/.zshrc:"
     echo "  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo "Next: emuu doctor"
