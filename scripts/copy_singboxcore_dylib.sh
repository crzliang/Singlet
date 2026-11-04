#!/usr/bin/env bash
# Copy libsingboxcore.dylib into the macOS .app Frameworks folder.
# Invoked from Xcode Run Script (see macos/Runner.xcodeproj) and usable manually.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT/native/singboxcore"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) GOARCH=arm64 ;;
  x86_64) GOARCH=amd64 ;;
  *) GOARCH=arm64 ;;
esac

SRC=""
for candidate in \
  "$CORE_DIR/build/universal/libsingboxcore.dylib" \
  "$CORE_DIR/build/$GOARCH/libsingboxcore.dylib"
do
  if [[ -f "$candidate" ]]; then
    SRC="$candidate"
    break
  fi
done

if [[ -z "$SRC" ]]; then
  echo "error: libsingboxcore.dylib not found. Run: make -C native/singboxcore" >&2
  exit 1
fi

# When run from Xcode, TARGET_BUILD_DIR / CONTENTS_FOLDER_PATH are set.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${CONTENTS_FOLDER_PATH:-}" ]]; then
  DEST_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Frameworks"
else
  # Manual / CI fallback: first arg = .app path
  APP_PATH="${1:-}"
  if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "usage: $0 /path/to/Singlet.app   (or run as Xcode script)" >&2
    exit 1
  fi
  DEST_DIR="$APP_PATH/Contents/Frameworks"
fi

mkdir -p "$DEST_DIR"
cp -f "$SRC" "$DEST_DIR/libsingboxcore.dylib"
# Ad-hoc codesign so hardened runtime / Gatekeeper path is happier for local runs.
if command -v codesign >/dev/null 2>&1; then
  codesign --force -s - "$DEST_DIR/libsingboxcore.dylib" 2>/dev/null || true
fi
echo "Copied $SRC → $DEST_DIR/libsingboxcore.dylib"
