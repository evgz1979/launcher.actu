#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Launcher.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

swift build -c release --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$ROOT/.build/release/Launcher" "$MACOS/Launcher"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/launcher.json" "$RESOURCES/launcher.json"

echo "Built $APP"
