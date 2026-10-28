#!/bin/bash
# 编译 Dockolate 并组装 .app bundle
# 用法：./build.sh [--install]   （--install 会部署到 ~/Applications）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dockolate"
BUNDLE_ID="io.github.autugit.dockolate"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> 清理"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译（swiftc -O，Swift 5 语言模式，多文件）"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa \
  src/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 打包签名表资源"
if [[ -f resources/adapters.json ]]; then
  cp resources/adapters.json "$APP/Contents/Resources/adapters.json"
else
  echo "    ⚠ 缺 resources/adapters.json：应用会只用内置默认判定"
fi

echo "==> 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>           <string>1.5.0</string>
    <key>CFBundleShortVersionString</key><string>1.5.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 本地 ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true

echo "==> 产物：$(pwd)/$APP"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> 部署到 ~/Applications"
  mkdir -p "$HOME/Applications"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$HOME/Applications/$APP_NAME.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "已安装：$HOME/Applications/$APP_NAME.app"
fi
