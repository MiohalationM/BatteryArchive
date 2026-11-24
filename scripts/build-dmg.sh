#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# 最低系统要求：macOS 14.0（Sonoma）
# 始终复用 scripts/build-app.sh 的签名 App + Helper，避免 DMG 脚本产生未签名或残留旧 Helper
# 的第二套产物。支持通过第一个参数自定义输出文件名（默认 BatteryArchive.dmg）。

APP_NAME="BatteryArchive"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="${1:-BatteryArchive.dmg}"
DMG_DIR="$BUILD_DIR/dmg"
VOLUME_NAME="BatteryArchive"

echo "=== Building signed app bundle ==="
bash scripts/build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"

echo "=== Creating DMG ($DMG_NAME) ==="
rm -rf "$DMG_DIR"
rm -f "$DMG_NAME"
mkdir -p "$DMG_DIR"
mkdir -p "$(dirname "$DMG_NAME")"

# 复制 app 到 DMG 目录
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# 创建 Applications 快捷方式
ln -s /Applications "$DMG_DIR/Applications"

# 创建压缩 DMG
hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$DMG_NAME"

echo "=== Verifying DMG ==="
hdiutil verify "$DMG_NAME"

echo ""
echo "=== Done ==="
echo "DMG created: $DMG_NAME"
echo "Size: $(du -h "$DMG_NAME" | cut -f1)"
echo "SHA-256: $(shasum -a 256 "$DMG_NAME")"
echo ""
echo "To install:"
echo "1. Open $DMG_NAME"
echo "2. Drag BatteryArchive to Applications"
echo "3. Launch from Applications or Spotlight"
