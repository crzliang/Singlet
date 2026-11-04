#!/usr/bin/env bash
# Build helper binary into helper/SingletPrivilegedHelper/build/ and optionally
# into the macOS .app Resources (when run from Xcode).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/helper/SingletPrivilegedHelper/main.swift"
OUT_DIR="$ROOT/helper/SingletPrivilegedHelper/build"
BIN="$OUT_DIR/com.singlet.PrivilegedHelper"
PLIST_SRC="$ROOT/helper/SingletPrivilegedHelper/com.singlet.PrivilegedHelper.plist"

mkdir -p "$OUT_DIR"
swiftc -parse-as-library -O "$SRC" -o "$BIN"
chmod 755 "$BIN"
cp -f "$PLIST_SRC" "$OUT_DIR/com.singlet.PrivilegedHelper.plist"
echo "Built $BIN"

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Helper"
  mkdir -p "$DEST"
  cp -f "$BIN" "$DEST/com.singlet.PrivilegedHelper"
  cp -f "$OUT_DIR/com.singlet.PrivilegedHelper.plist" "$DEST/com.singlet.PrivilegedHelper.plist"
  # Ad-hoc sign for local personal use.
  if command -v codesign >/dev/null 2>&1; then
    codesign --force -s - "$DEST/com.singlet.PrivilegedHelper" 2>/dev/null || true
  fi
  echo "Bundled helper → $DEST"
fi
