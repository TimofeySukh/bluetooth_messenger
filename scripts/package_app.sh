#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BluetoothMessenger"
DISPLAY_NAME="Bluetooth Messenger"
APP_DIR="$ROOT_DIR/dist/${DISPLAY_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ZIP_PATH="$ROOT_DIR/dist/BluetoothMessenger-macOS.zip"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$APP_DIR" "$ICONSET_DIR" "$ZIP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ICONSET_DIR" "$ROOT_DIR/dist"

cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

sips -z 16 16     "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
sips -z 32 32     "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
sips -z 64 64     "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
sips -z 256 256   "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
sips -z 512 512   "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "Assets/AppIcon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"

chmod +x "$MACOS_DIR/$APP_NAME"

ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "Built $APP_DIR"
echo "Created $ZIP_PATH"
