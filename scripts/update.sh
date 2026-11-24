#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

# 最低系统要求：macOS 14.0（Sonoma）
# 安全更新流程：先编译并严格验签，再优雅关闭运行中的应用、备份替换并验签；
# 若复制或安装后验签失败，自动回滚至原安装版并重新启动。

APP_NAME="BatteryArchive"
BUNDLE_ID="com.batteryarchive.app"
INSTALL_ROOT="${BATTERYARCHIVE_INSTALL_DIR:-$HOME/Applications}"
APP_PATH="$INSTALL_ROOT/$APP_NAME.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
BACKUP_PATH="$INSTALL_ROOT/$APP_NAME.pre-update.$$.app"

rollback_and_exit() {
    local reason="$1"
    echo "ERROR: $reason，正在回滚至更新前版本..." >&2
    rm -rf "$APP_PATH"
    if [ -e "$BACKUP_PATH" ]; then
        mv "$BACKUP_PATH" "$APP_PATH"
        open "$APP_PATH" 2>/dev/null || true
        echo "已恢复并重新启动原安装版：$APP_PATH" >&2
    fi
    exit 1
}

echo "=== 正在更新 $APP_NAME ==="

# 1. 先编译并严格验签：若构建或签名失败，不影响正在运行的已安装版本
echo "编译并签名中..."
bash scripts/build-app.sh
codesign --verify --deep --strict "$APP_BUNDLE"

# 2. 构建与签名通过后再优雅退出运行中的应用（给 applicationWillTerminate 最多 2 秒排空落盘）
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "正在优雅关闭运行中的应用..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
    for _ in $(seq 1 10); do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            break
        fi
        sleep 0.2
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        echo "等待退出超时，结束残留进程..."
        pkill -x "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
fi

# 3. 备份现有安装版并安装新版本
echo "安装到 $INSTALL_ROOT..."
mkdir -p "$INSTALL_ROOT"
if [ -e "$APP_PATH" ]; then
    mv "$APP_PATH" "$BACKUP_PATH"
fi

if ! ditto "$APP_BUNDLE" "$APP_PATH"; then
    rollback_and_exit "复制新版本到 $APP_PATH 失败"
fi

# 4. 安装后严格验签，失败则自动回滚并重启旧版
if ! codesign --verify --deep --strict "$APP_PATH"; then
    rollback_and_exit "安装后签名校验失败"
fi

# 5. 清理备份并启动新版本
if [ -e "$BACKUP_PATH" ]; then
    rm -rf "$BACKUP_PATH"
fi

echo "启动应用..."
open "$APP_PATH"

echo ""
echo "=== 更新完成 ==="
echo "BatteryArchive 已更新并启动"
echo ""
echo "首次开启高级采样时会安装后台服务（需要管理员授权）"
