#!/bin/bash
# ==========================================
# 构建 UsageBar.app（macOS 菜单栏用量查看器）
# 用法: ./build-app.sh
# 产物: build/UsageBar.app
# ==========================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="UsageBar"
APP="build/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP"

echo ""
echo "✅ 完成: $(cd build && pwd)/$APP_NAME.app"
echo "运行:   open $APP"
