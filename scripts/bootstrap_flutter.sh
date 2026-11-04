#!/usr/bin/env bash
# Ensure Flutter macOS project exists at repo root, then remind about custom channels.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK not on PATH."
  echo "Install: https://docs.flutter.dev/get-started/install/macos"
  echo "Or: export PATH=\"\$HOME/sdk/flutter/bin:\$PATH\""
  exit 1
fi

if [[ ! -f pubspec.yaml ]]; then
  flutter create --org com.singlet --project-name singlet --platforms=macos .
else
  flutter create --platforms=macos .
fi

flutter pub get
echo "OK. Next: flutter run -d macos"
