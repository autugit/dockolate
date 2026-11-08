#!/bin/bash
# ============================================================
# 只换 DockolateHub 这一个包（中枢）
# ============================================================
# 场景：GUI 本体（Dockolate.app）没变，只改了中枢的图标/资源，不想跑整套
#       tools/install-system.command 把两个包都重装。
# 用法：双击本文件；或 bash tools/install-hub-app.command
# 前置：先 ./build.sh（产物在 build/DockolateHub.app）
set -uo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PROJ/build/DockolateHub.app"
DST="/Applications/DockolateHub.app"
PREV="$HOME/Applications/_prev"
STAMP="$(date +%Y%m%d-%H%M%S)"
LABEL="gui/$(id -u)/ai.local.model-hub"
PLIST="$HOME/Library/LaunchAgents/ai.local.model-hub.plist"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

die() { echo "❌ $*"; echo; read -r -p "按回车关闭…" _ || true; exit 1; }

[[ -d "$SRC" ]] || die "没有 $SRC —— 先在项目里跑 ./build.sh"

echo "==> 需要管理员密码（/Applications 下的包属主是 root:wheel）"
sudo -v || die "没拿到管理员权限"

echo "==> 停中枢"
launchctl bootout "$LABEL" 2>/dev/null || true
sleep 1

echo "==> 换包（旧包挪到 ~/Applications/_prev，不删除）"
mkdir -p "$PREV"
if [[ -d "$DST" ]]; then
  sudo mv "$DST" "$PREV/DockolateHub-$STAMP.app" || die "旧包挪不动"
  sudo chown -R "$(id -u)":staff "$PREV/DockolateHub-$STAMP.app" 2>/dev/null || true
  echo "   · 旧包 → _prev/DockolateHub-$STAMP.app"
fi
sudo cp -R "$SRC" "$DST" || die "复制新包失败"
sudo chown -R root:wheel "$DST"
sudo chmod -R go-w "$DST"
sudo chmod -R a-w "$DST"
sudo chmod -R u+rxX "$DST"

echo "==> 启中枢"
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || echo "   ⚠ bootstrap 失败，手动：launchctl bootstrap gui/$(id -u) \"$PLIST\""

echo "==> 刷新图标缓存"
touch "$DST"
"$LSR" -f "$DST" >/dev/null 2>&1 || true

echo "==> 校验"
echo -n "   CFBundleIconFile: "; /usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$DST/Contents/Info.plist" 2>/dev/null || echo "（无）"
ls -l "$DST/Contents/Resources/DockolateHub.icns" 2>/dev/null | sed 's/^/   /' || echo "   ⚠ 包里没有 icns"
codesign --verify --deep --strict "$DST" >/dev/null 2>&1 && echo "   ✓ 签名 OK" || echo "   ⚠ 签名校验失败"
pgrep -f "DockolateHub.app" >/dev/null && echo "   ✓ 中枢在跑（pid $(pgrep -f DockolateHub.app | tr '\n' ' '))" || echo "   ⚠ 中枢没起来"

echo
echo "✅ 完成。Finder/启动台里 DockolateHub 应显示『同一块巧克力 + 中心一枚琥珀接点』。"
echo "   （若仍显示旧图标：注销重登，或在本终端执行 killall Dock）"
echo
read -r -p "按回车关闭…" _ || true
