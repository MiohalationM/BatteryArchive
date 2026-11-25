#!/bin/bash
set -euo pipefail

# 开发者手动安装入口。生产 UI 使用 HelperInstaller 内的同等安全流程；这里不再安装
# debug/未签名二进制，也不生成 RunAtLoad/KeepAlive 常驻 daemon。
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$REPO_ROOT/.build/release/BatteryArchive.app"
HELPER_SOURCE="$APP_BUNDLE/Contents/Resources/BatteryArchiveHelper"
HELPER_ID="com.batteryarchive.helper"
INSTALL_PATH="/Library/PrivilegedHelperTools/$HELPER_ID"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_ID.plist"

cd "$REPO_ROOT"
bash scripts/build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"
codesign --verify --strict "$HELPER_SOURCE"

CLIENT_CDHASH="$(codesign -dvvv "$APP_BUNDLE/Contents/MacOS/BatteryArchive" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
if [[ ! "$CLIENT_CDHASH" =~ ^[0-9a-fA-F]{40,64}$ ]]; then
    echo "无法取得已签名主程序 CDHash，拒绝安装" >&2
    exit 2
fi

EXPECTED_SHA256="$(/usr/bin/shasum -a 256 "$HELPER_SOURCE")"
EXPECTED_SHA256="${EXPECTED_SHA256%% *}"
PLIST_CONTENT=$(cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$HELPER_ID</string>
    <key>ProgramArguments</key>
    <array><string>$INSTALL_PATH</string></array>
    <key>MachServices</key>
    <dict><key>$HELPER_ID</key><true/></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>BATTERYARCHIVE_AUTHORIZED_CLIENT_CDHASH</key>
        <string>$CLIENT_CDHASH</string>
    </dict>
</dict>
</plist>
PLIST
)

# Keep this literal equal to HelperInstaller.installShellScript (covered by tests).
# Capture code and arguments before authorization; root never executes a user-writable script file.
ROOT_INSTALL_SCRIPT=$(cat <<'SH'
set -eu
source=$1; destination=$2; plistDestination=$3; plistContents=$4; expected=$5
umask 077
stage=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$destination")/.batteryarchive.XXXXXXXX")
trap '/bin/rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
/bin/cp -P "$source" "$stage/helper"
test -f "$stage/helper" && test ! -L "$stage/helper"
actual=$(/usr/bin/shasum -a 256 "$stage/helper")
test "${actual%% *}" = "$expected"
/usr/bin/codesign --verify --strict "$stage/helper"
/usr/bin/printf %s "$plistContents" > "$stage/daemon.plist"
/usr/bin/plutil -lint "$stage/daemon.plist" >/dev/null
/usr/sbin/chown root:wheel "$stage/helper" "$stage/daemon.plist"
/bin/chmod 755 "$stage/helper"
/bin/chmod 644 "$stage/daemon.plist"
/bin/launchctl bootout system/com.batteryarchive.helper 2>/dev/null || true
/bin/launchctl bootout system/com.batterybar.helper 2>/dev/null || true
/bin/rm -f /Library/PrivilegedHelperTools/com.batterybar.helper /Library/LaunchDaemons/com.batterybar.helper.plist
/bin/mv -fh "$stage/helper" "$destination"
/bin/mv -fh "$stage/daemon.plist" "$plistDestination"
/bin/launchctl bootstrap system/ "$plistDestination"
SH
)

echo "将安装按需启动的 BatteryArchive Helper；需要管理员授权。"
sudo /bin/mkdir -p /Library/PrivilegedHelperTools
sudo /bin/sh -c "$ROOT_INSTALL_SCRIPT" -- "$HELPER_SOURCE" "$INSTALL_PATH" "$PLIST_PATH" "$PLIST_CONTENT" "$EXPECTED_SHA256"
echo "安装完成：Helper 将由 XPC 请求按需启动，并在空闲后退出。"
