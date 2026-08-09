#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Launcher.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

xcrun swiftc \
  -O \
  -framework AppKit \
  -framework SystemConfiguration \
  "$ROOT/Sources/Launcher/main.swift" \
  -o "$MACOS/Launcher"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $APP"
