#!/usr/bin/env bash
set -euo pipefail

HUD_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP="$HUD_ROOT/dist/TokenLensHUD.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

ZIP_OUT=""
if [[ "${1:-}" == "--zip" && -n "${2:-}" ]]; then
  ZIP_OUT="$2"
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="arm64-apple-macos14.0"
else
  TARGET="x86_64-apple-macos14.0"
fi

mkdir -p "$MACOS" "$RESOURCES"
cp "$HUD_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$HUD_ROOT/Resources/icon.icns" ]]; then
  cp "$HUD_ROOT/Resources/icon.icns" "$RESOURCES/icon.icns"
fi

swiftc \
  -O \
  -target "$TARGET" \
  -swift-version 5 \
  -framework AppKit \
  -framework SwiftUI \
  -framework CoreGraphics \
  -framework CFNetwork \
  -lsqlite3 \
  "$HUD_ROOT/Sources/Protobuf.swift" \
  "$HUD_ROOT/Sources/DataStore.swift" \
  "$HUD_ROOT/Sources/QuotaService.swift" \
  "$HUD_ROOT/Sources/Views.swift" \
  "$HUD_ROOT/Sources/main.swift" \
  -o "$MACOS/TokenLensHUD"

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($TARGET, $(du -sh "$APP" | awk '{print $1}'))"

if [[ -n "$ZIP_OUT" ]]; then
  mkdir -p "$(dirname -- "$ZIP_OUT")"
  rm -f "$ZIP_OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_OUT"
  echo "Packaged $ZIP_OUT ($(du -sh "$ZIP_OUT" | awk '{print $1}'))"
fi
