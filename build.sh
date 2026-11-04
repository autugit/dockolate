#!/bin/bash
# 编译 Dockolate 并组装 .app bundle
# 用法：./build.sh [--install]   （--install 会部署到 ~/Applications）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Dockolate"

# ---- 回滚：用 ~/Applications/_prev 里最近的一份替换当前安装 ----
if [[ "${1:-}" == "--rollback" ]]; then
  PREV="$HOME/Applications/_prev"
  LATEST=$(ls -1dt "$PREV"/$APP_NAME-*.app 2>/dev/null | head -1)
  [[ -n "$LATEST" ]] || { echo "没有可回滚的旧版本（$PREV 为空）"; exit 1; }
  CUR="$HOME/Applications/$APP_NAME.app"
  if [[ -d "$CUR" ]]; then
    mv "$CUR" "$PREV/$APP_NAME-broken-$(date +%Y%m%d-%H%M%S).app"
  fi
  cp -R "$LATEST" "$CUR"
  echo "已回滚到：$(basename "$LATEST")"
  echo "重启：launchctl kickstart -k gui/$(id -u)/io.github.autugit.dockolate   （或重开 App）"
  exit 0
fi

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

echo "==> 图标"
# 图标由 tools/icon_from_image.py（有 resources/icon-source.jpg 时）或 tools/make_icon.py 生成，
# 结果落在 build/icon/Dockolate.icns。这里只负责拷进 bundle：
# 把出图/渲染从构建脚本里拆出去，构建过程不依赖图片素材，也不引入外部读取。
ICNS="build/icon/Dockolate.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$APP/Contents/Resources/Dockolate.icns"
else
  echo "    ⚠ 无 icns（先跑 tools/icon_from_image.py 或 tools/make_icon.py）"
  echo "    提示：图标源图改动后不会自动重生成，需手动跑生成脚本再构建"
fi

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
    <key>CFBundleVersion</key>           <string>1.8.0</string>
    <key>CFBundleShortVersionString</key><string>1.8.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>Dockolate</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <false/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 中枢后台（独立 bundle：它的 bundle id 与 GUI 不同，才不会被 LaunchServices 当成同一个 app）"
HUB_APP="$BUILD_DIR/DockolateHub.app"
rm -rf "$HUB_APP"
mkdir -p "$HUB_APP/Contents/MacOS" "$HUB_APP/Contents/Resources"
cp "$APP/Contents/MacOS/$APP_NAME" "$HUB_APP/Contents/MacOS/$APP_NAME"
[[ -f resources/adapters.json ]] && cp resources/adapters.json "$HUB_APP/Contents/Resources/" || true
cat > "$HUB_APP/Contents/Info.plist" <<HUBPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>DockolateHub</string>
    <key>CFBundleDisplayName</key>       <string>Dockolate Hub</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID.hub</string>
    <key>CFBundleVersion</key>           <string>1.8.0</string>
    <key>CFBundleShortVersionString</key><string>1.8.0</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
HUBPLIST

echo "==> 完整性清单（manifest：给 --doctor 与启动自检用）"
write_manifest() {
  local BUNDLE="$1" TARGET="$2"
  {
    echo '{'
    echo '  "generated_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
    echo '  "files": ['
    # 只列**资源**：可执行文件的完整性由代码签名负责（内核 + codesign --verify），
    # 它的字节在签名后会被改写，放进哈希清单必然对不上（实测踩过）。
    local first=1 f hash size
    for f in "Contents/Resources/adapters.json" "Contents/Resources/$APP_NAME.icns"; do
      [[ -f "$BUNDLE/$f" ]] || continue
      hash=$(shasum -a 256 "$BUNDLE/$f" | awk '{print $1}')
      size=$(stat -f%z "$BUNDLE/$f")
      [[ $first -eq 1 ]] || echo ','
      first=0
      printf '    {"path": "%s", "sha256": "%s", "bytes": %s}' "$f" "$hash" "$size"
    done
    echo
    echo '  ]'
    echo '}'
  } > "$BUNDLE/$TARGET"
}
# manifest 必须在签名**之前**写：签名会把它封进资源封条，之后任何资源改动都能被 codesign 发现
write_manifest "$APP" "Contents/Resources/manifest.json"

echo "==> 本地 ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
write_manifest "$HUB_APP" "Contents/Resources/manifest.json"
codesign --force --deep --sign - "$HUB_APP" 2>&1 | grep -v "replacing existing signature" || true

echo "==> 产物：$(pwd)/$APP  +  $(pwd)/$HUB_APP"
du -sh "$APP"

if [[ "${1:-}" == "--install" ]]; then
  if [[ -d "/Applications/Dockolate.app" ]]; then
    echo "⚠️  /Applications 里已有系统版（root 只读）。这份装到 ~/Applications 的是开发版，"
    echo "    同时跑会出现两个 Dock 图标；要发布就改用：bash tools/install-system.command"
  fi
  echo "==> 部署到 ~/Applications"
  mkdir -p "$HOME/Applications" "$HOME/Applications/_prev"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  # 安装前把旧版整体挪到 _prev（保留最近 3 份，可 build.sh --rollback 回滚）
  STAMP=$(date +%Y%m%d-%H%M%S)
  if [[ -d "$HOME/Applications/$APP_NAME.app" ]]; then
    mv "$HOME/Applications/$APP_NAME.app" "$HOME/Applications/_prev/$APP_NAME-$STAMP.app"
  fi
  if [[ -d "$HOME/Applications/DockolateHub.app" ]]; then
    mv "$HOME/Applications/DockolateHub.app" "$HOME/Applications/_prev/DockolateHub-$STAMP.app"
  fi
  ls -1dt "$HOME/Applications/_prev/$APP_NAME-"*.app 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done
  ls -1dt "$HOME/Applications/_prev/DockolateHub-"*.app 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done
  cp -R "$APP" "$HOME/Applications/"
  # 中枢后台也装到 ~/Applications（独立 bundle，不再与 GUI 抢身份）
  cp -R "$HUB_APP" "$HOME/Applications/"
  # 让 Finder / Dock 重新读图标（bundle 被整体替换过，缓存会指着旧 inode）
  touch "$HOME/Applications/$APP_NAME.app"
  echo "已安装：$HOME/Applications/$APP_NAME.app"
fi
