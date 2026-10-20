#!/bin/bash
# 部署 Dockolate：编译 → 装到 ~/Applications → 注册 LaunchAgent（登录自启 + 崩溃自拉起）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Dockolate"
LABEL="io.github.autugit.dockolate"
SRC_APP="build/$APP_NAME.app"
DST_APP="$HOME/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 1/4 编译"
bash build.sh

echo "==> 2/4 停止旧实例"
# 先按 label 卸载（launchd 管的实例）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 再清掉手动启动的实例（精确匹配进程名，不动别的）
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  for pid in $(pgrep -x "$APP_NAME"); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
fi

echo "==> 3/4 安装到 ~/Applications"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DST_APP"
cp -R "$SRC_APP" "$DST_APP"

echo "==> 4/4 写 LaunchAgent 并加载"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DST_APP/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/Dockolate.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/Dockolate.err.log</string>
</dict>
</plist>
PLIST

mkdir -p "$HOME/Library/Logs"
launchctl bootstrap "gui/$(id -u)" "$AGENT"
sleep 2

echo
echo "==> 状态"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "^\s*(state|pid|program|runs) " | sed 's/^/    /'
echo "==> 进程"
pgrep -lx "$APP_NAME" | sed 's/^/    /' || echo "    (未运行)"
echo
echo "完成。Dock 里应已出现 Dockolate 图标；菜单栏右侧有 C/G/M 读数。"
echo "卸载：launchctl bootout gui/$(id -u)/$LABEL && rm -rf $DST_APP $AGENT"
