#!/usr/bin/env bash
# Build Release Singlet.app and wrap it in a DMG (ad-hoc signed, personal use).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/sdk/flutter/bin:/opt/homebrew/bin:${PATH:-}"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"

cd "$ROOT"

VERSION="$(python3 - <<'PY'
import re, pathlib
t = pathlib.Path("pubspec.yaml").read_text()
m = re.search(r"^version:\s*([^\s#+]+)", t, re.M)
print(m.group(1) if m else "0.0.0")
PY
)"
BUILD_NUM="$(python3 - <<'PY'
import re, pathlib
t = pathlib.Path("pubspec.yaml").read_text()
m = re.search(r"^version:\s*[^\s+]+\+(\d+)", t, re.M)
print(m.group(1) if m else "0")
PY
)"

DIST="$ROOT/dist"
STAGE="$DIST/dmg-stage"
VOL="Singlet ${VERSION}"
APP_NAME="Singlet.app"
DMG_NAME="Singlet-${VERSION}+${BUILD_NUM}-macos-arm64.dmg"
DMG_PATH="$DIST/$DMG_NAME"

echo "==> sing-box core"
make -C native/singboxcore

echo "==> privileged helper"
bash scripts/build_privileged_helper.sh

echo "==> flutter build macos --release"
flutter pub get
flutter build macos --release

APP_SRC=""
for candidate in \
  "$ROOT/build/macos/Build/Products/Release/${APP_NAME}" \
  "$ROOT/build/macos/Build/Products/Release/Runner.app" \
  "$ROOT/build/macos/Build/Products/Release/Singlet.app"
do
  if [[ -d "$candidate" ]]; then
    APP_SRC="$candidate"
    break
  fi
done
if [[ -z "$APP_SRC" ]]; then
  echo "error: Release .app not found under build/macos/Build/Products/Release" >&2
  ls -la "$ROOT/build/macos/Build/Products/Release" >&2 || true
  exit 1
fi

echo "==> ensure dylib + helper inside ${APP_SRC}"
bash scripts/copy_singboxcore_dylib.sh "$APP_SRC"
# Helper is normally copied by Xcode script; re-copy for safety.
HELPER_DEST="$APP_SRC/Contents/Resources/Helper"
mkdir -p "$HELPER_DEST"
cp -f helper/SingletPrivilegedHelper/build/com.singlet.PrivilegedHelper \
  "$HELPER_DEST/com.singlet.PrivilegedHelper"
cp -f helper/SingletPrivilegedHelper/build/com.singlet.PrivilegedHelper.plist \
  "$HELPER_DEST/com.singlet.PrivilegedHelper.plist"
chmod 755 "$HELPER_DEST/com.singlet.PrivilegedHelper"

echo "==> ad-hoc codesign"
codesign --force --deep --sign - \
  --entitlements macos/Runner/Release.entitlements \
  "$APP_SRC" 2>/dev/null || codesign --force --deep --sign - "$APP_SRC"

echo "==> stage DMG contents"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP_SRC" "$STAGE/${APP_NAME}"
ln -sf /Applications "$STAGE/Applications"

# Optional readme for first open
cat > "$STAGE/安装说明.txt" <<EOF
Singlet  (${BUILD_NUM})

1. 将 Singlet.app 拖到 Applications
2. 首次打开：右键 → 打开（或系统设置 → 隐私与安全性 允许）
3. TUN：在应用设置里安装 Privileged Helper（需管理员密码）

未公证 / 仅 ad-hoc 签名，适合本机自用。
EOF

echo "==> create ${DMG_PATH}"
mkdir -p "$DIST"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGE"

echo
echo "OK: $DMG_PATH"
ls -lh "$DMG_PATH"
codesign -dv --verbose=2 "$APP_SRC" 2>&1 | head -15 || true
