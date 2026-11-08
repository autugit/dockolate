#!/bin/bash
# ============================================================
# 把 Dockolate 装进 /Applications 并设为「只有 root 能改」
# ============================================================
# 为什么要这样：程序本体要能被 AI 放心调用，就不能让同用户进程随手覆盖。
#   · ~/Applications 里那份 = 开发版（自己可写，方便反复 build）
#   · /Applications 里这份 = 发布版（root:wheel，权限只读；升级只能整体替换）
#
# 用法：双击本文件（会自动打开终端并让你输管理员密码），或者
#   bash tools/install-system.command
#
# 升级：在项目里 ./build.sh 之后，再跑一次本脚本。
# 卸载：tools/uninstall-system.command
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

APP_SRC="$PROJ/build/Dockolate.app"
HUB_SRC="$PROJ/build/DockolateHub.app"
APP_DST="/Applications/Dockolate.app"
HUB_DST="/Applications/DockolateHub.app"
LABEL_GUI="io.github.autugit.dockolate"
LABEL_HUB="ai.local.model-hub"
UID_NUM="$(id -u)"

die() { echo "❌ $*"; echo; read -r -p "按回车关闭…" _ || true; exit 1; }

[[ -x "$APP_SRC/Contents/MacOS/Dockolate" ]] || die "没有 $APP_SRC —— 先跑 ./build.sh"
[[ -x "$HUB_SRC/Contents/MacOS/Dockolate" ]] || die "没有 $HUB_SRC —— 先跑 ./build.sh"

echo "==> 需要管理员密码：装到 /Applications 并 chown root:wheel + 去写权限"
sudo -v || die "没拿到管理员权限"

echo "==> 停掉正在跑的实例"
launchctl bootout "gui/$UID_NUM/$LABEL_GUI" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$LABEL_HUB" 2>/dev/null || true
pkill -x Dockolate 2>/dev/null || true
sleep 1

echo "==> 安装（整体替换，先留旧版到 ~/Applications/_prev）"
mkdir -p "$HOME/Applications/_prev"
STAMP=$(date +%Y%m%d-%H%M%S)

# 先清扫历史残留：/Applications 里 _Dockolate*.app 这类「旧版改名包」是早期替换流程
# 留下的孤儿（没有任何 LaunchAgent 引用），会让「应用程序」里堆出一排重复图标。
# 一律挪进 _prev 留档，不删除。
shopt -s nullglob
for stale in /Applications/_Dockolate*.app; do
  base="$(basename "$stale" .app)"
  if sudo mv "$stale" "$HOME/Applications/_prev/$base-$STAMP.app"; then
    sudo chown -R "$UID_NUM":staff "$HOME/Applications/_prev/$base-$STAMP.app" 2>/dev/null || true
    echo "   · 残留已归位 _prev/$base-$STAMP.app"
  else
    echo "   ⚠ 残留 $base 挪不动，跳过"
  fi
done
shopt -u nullglob

for pair in "$APP_DST:Dockolate" "$HUB_DST:DockolateHub"; do
  dst="${pair%%:*}"; name="${pair##*:}"
  if [[ -d "$dst" ]]; then
    sudo mv "$dst" "$HOME/Applications/_prev/$name-system-$STAMP.app"
    sudo chown -R "$UID_NUM":staff "$HOME/Applications/_prev/$name-system-$STAMP.app" 2>/dev/null || true
  fi
done
sudo rm -rf "$APP_DST" "$HUB_DST"
sudo cp -R "$APP_SRC" "$APP_DST"
sudo cp -R "$HUB_SRC" "$HUB_DST"

echo "==> 收紧权限（root:wheel，所有人去写）"
sudo chown -R root:wheel "$APP_DST" "$HUB_DST"
sudo chmod -R go-w "$APP_DST" "$HUB_DST"
sudo chmod -R a-w "$APP_DST" "$HUB_DST"
sudo chmod -R u+rxX "$APP_DST" "$HUB_DST" 2>/dev/null || true

echo "==> 把 ~/Applications 里的开发版挪走（避免两个 Dock 图标抢身份）"
for pair in "$HOME/Applications/Dockolate.app:Dockolate" "$HOME/Applications/DockolateHub.app:DockolateHub"; do
  dst="${pair%%:*}"; name="${pair##*:}"
  [[ -d "$dst" ]] && mv "$dst" "$HOME/Applications/_prev/$name-dev-$STAMP.app" || true
done

echo "==> 重写 LaunchAgent（指向 /Applications）"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$HOME/Library/LaunchAgents/$LABEL_GUI.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL_GUI</string>
    <key>ProgramArguments</key><array><string>$APP_DST/Contents/MacOS/Dockolate</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/Dockolate.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Dockolate.err.log</string>
</dict>
</plist>
PLIST
cat > "$HOME/Library/LaunchAgents/$LABEL_HUB.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL_HUB</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HUB_DST/Contents/MacOS/Dockolate</string>
        <string>--hub</string>
        <string>--interval=5</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/local-model-hub/hub.out</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/local-model-hub/hub.err</string>
</dict>
</plist>
PLIST
mkdir -p "$HOME/Library/Logs/local-model-hub"

launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$LABEL_GUI.plist" || true
launchctl bootstrap "gui/$UID_NUM" "$HOME/Library/LaunchAgents/$LABEL_HUB.plist" || true

echo "==> 校验"
codesign --verify --deep --strict "$APP_DST" && echo "  签名 OK"
ls -ld "$APP_DST" | sed 's/^/  /'
"$APP_DST/Contents/MacOS/Dockolate" --doctor --text | sed 's/^/  /' || true

echo
echo "✅ 装好了：$APP_DST（root:wheel，只读）"
echo "   管理 API：$APP_DST/Contents/MacOS/Dockolate --api '{\"op\":\"help\"}'"
echo "   以后升级：./build.sh && bash tools/install-system.command"
echo
read -r -p "按回车关闭…" _ || true
