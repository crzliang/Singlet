#!/bin/bash
set -euo pipefail
export PATH="$HOME/sdk/flutter/bin:/opt/homebrew/bin:$PATH"
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
cd "$(dirname "$0")/.."

pkill -f 'Singlet.app/Contents/MacOS/Singlet' 2>/dev/null || true
pkill -f 'Singlet.app/Contents/MacOS/Singlet' 2>/dev/null || true
pkill -f 'flutter run' 2>/dev/null || true
sleep 1

make -C native/singboxcore
bash scripts/build_privileged_helper.sh
mkdir -p build/macos/Build/Products/Debug/Singlet.app/Contents/Frameworks
cp -f native/singboxcore/build/arm64/libsingboxcore.dylib \
  build/macos/Build/Products/Debug/Singlet.app/Contents/Frameworks/ 2>/dev/null || true
cp -f native/singboxcore/build/arm64/libsingboxcore.dylib \
  /tmp/com.singlet.libsingboxcore.dylib

exec flutter run -d macos
