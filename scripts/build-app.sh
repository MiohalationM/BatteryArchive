#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# 最低系统要求：macOS 14.0（Sonoma）
# Helper 安装方式：使用 osascript + sudo（不走 SMJobBless），故主应用与 helper 的
# Info.plist 不再包含 SMPrivilegedExecutables / SMAuthorizedClients。

APP_NAME="BatteryArchive"
PRODUCT_NAME="BatteryArchive"
APP_VERSION="1.1.0"
APP_BUILD="2"
ICON_RESOURCE_NAME="BatteryArchiveIcon"
HELPER_NAME="BatteryArchiveHelper"
# 分发使用 release 构建，确保空闲 CPU 占用最低
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BUNDLE_ID="com.batteryarchive.app"
HELPER_BUNDLE_ID="com.batteryarchive.helper"
ICON_DIR="Sources/BatteryArchive/Resources"

echo "=== 编译 $APP_NAME 和 $HELPER_NAME（release） ==="
swift build -c release

echo "=== 创建 App Bundle ==="
# 清理旧的 bundle
rm -rf "$APP_BUNDLE"

# 创建目录结构
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 复制主应用与唯一图标资源（去重以减小 App 与 DMG 体积）
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$ICON_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/$ICON_RESOURCE_NAME.icns"
mkdir -p "$APP_BUNDLE/Contents/Resources/en.lproj" "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj"
printf '%s\n' '"CFBundleName" = "BatteryArchive";' '"CFBundleDisplayName" = "BatteryArchive";' \
    > "$APP_BUNDLE/Contents/Resources/en.lproj/InfoPlist.strings"
printf '%s\n' '"CFBundleName" = "BatteryArchive";' '"CFBundleDisplayName" = "BatteryArchive";' \
    > "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

# === Helper 打包 ===
# Helper 暂存为 bundle（保留 Info.plist 和签名步骤），最终只把已签名的可执行文件
# 放入 app bundle 的 Resources，供 Bundle.main.path(forResource:) 查找。
# 运行时通过 osascript 安装到 /Library/PrivilegedHelperTools，不走 SMJobBless。
HELPER_STAGING="$BUILD_DIR/BatteryArchiveHelper.bundle"
rm -rf "$HELPER_STAGING"
mkdir -p "$HELPER_STAGING/Contents/MacOS"
cp "$BUILD_DIR/$HELPER_NAME" "$HELPER_STAGING/Contents/MacOS/"

echo "=== 创建 Info.plist ==="

# 主应用 Info.plist（无 SMPrivilegedExecutables，使用 osascript 安装 helper）
cat > "$APP_BUNDLE/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$ICON_RESOURCE_NAME</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Helper Info.plist（无 SMAuthorizedClients，使用 osascript 安装，不走 SMJobBless）
cat > "$HELPER_STAGING/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$HELPER_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$HELPER_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$HELPER_NAME</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

echo "=== 代码签名 ==="
# 签名 helper bundle
codesign --force --sign - --entitlements /dev/stdin "$HELPER_STAGING" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# 复制已签名 helper 可执行文件到 app bundle 的 Resources
cp "$HELPER_STAGING/Contents/MacOS/$HELPER_NAME" "$APP_BUNDLE/Contents/Resources/"

# 从 bundle 抽出的 Mach-O 不能沿用依赖 Info.plist 的旧签名；按其最终部署形态
# 重新签名为独立 helper，否则严格校验与运行时 SecStaticCode 校验都会失败。
codesign --force --sign - --identifier "$HELPER_BUNDLE_ID" --entitlements /dev/stdin \
    "$APP_BUNDLE/Contents/Resources/$HELPER_NAME" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# 签名主应用
codesign --force --sign - --entitlements /dev/stdin "$APP_BUNDLE" << 'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

# 发行门禁：主应用和内嵌 helper 必须都能独立通过签名验证；release 主程序不得
# 携带只为本地调试保留的 helper 路径覆盖入口。
codesign --verify --deep --strict "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE/Contents/Resources/$HELPER_NAME"
if strings "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q 'BATTERYARCHIVE_HELPER_PATH'; then
    echo "ERROR: release binary contains debug-only helper path override" >&2
    exit 1
fi

echo "=== 完成 ==="
echo "App Bundle: $APP_BUNDLE"
echo "Helper: $APP_BUNDLE/Contents/Resources/$HELPER_NAME"
echo ""
echo "运行: open $APP_BUNDLE"
