#!/bin/bash
# 把仓内 build/ 的两个 app 装到 /Applications（需要 sudo）
#
# 为什么需要 sudo：/Applications 下的 Dockolate*.app 由 root 所有，且 macOS 的
# 「App 管理」保护不允许非授权进程改名/覆盖它们。
#
# 可重入设计（可以反复跑）：
#   · 目标二进制与源文件 sha256 相同 ⇒ 跳过，不重复搬；
#   · 旧包**改名挪进** ~/Applications/_prev/，不删除，可回滚；
#   · 搬 DockolateHub.app 前先 bootout 中枢 —— 运行中的 app bundle 会被系统挡住 mv；
#   · 装完自动把中枢 bootstrap 回来，并把新包属主改成 $SUDO_USER（以后升级免 sudo）。
#
# 用法：sudo bash install-to-applications.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/build"
DEST=/Applications
STAMP="$(date +%Y%m%d-%H%M%S)"
PREV="$HOME/Applications/_prev"
OWNER="${SUDO_USER:-$(id -un)}"
TARGET_UID="${SUDO_UID:-$(id -u)}"
HUB_LABEL="gui/$TARGET_UID/ai.local.model-hub"
HUB_PLIST="$HOME/Library/LaunchAgents/ai.local.model-hub.plist"

for A in Dockolate DockolateHub; do
  [ -d "$SRC/$A.app" ] || { echo "✗ 找不到 $SRC/$A.app —— 先在仓里跑 bash build.sh"; exit 1; }
done
mkdir -p "$PREV"

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# 中枢在跑就先停：运行中的 app bundle 会让 mv 被系统拒掉
if launchctl print "$HUB_LABEL" >/dev/null 2>&1; then
  echo "· 先停中枢（$HUB_LABEL）"
  launchctl bootout "$HUB_LABEL" 2>/dev/null || true
  sleep 1
fi

FAILED=0
for A in Dockolate DockolateHub; do
  NEW="$SRC/$A.app/Contents/MacOS/Dockolate"
  CUR="$DEST/$A.app/Contents/MacOS/Dockolate"
  if [ -f "$CUR" ] && [ "$(sha "$CUR")" = "$(sha "$NEW")" ]; then
    echo "· $A.app 已是最新（sha 相同），跳过"
    chown -R "$OWNER" "$DEST/$A.app" 2>/dev/null || true
    continue
  fi
  if [ -d "$DEST/$A.app" ]; then
    if mv "$DEST/$A.app" "$PREV/$A-$STAMP.app"; then
      echo "· 旧包已挪到 $PREV/$A-$STAMP.app"
    else
      echo "✗ 挪走 $A.app 失败（旧包未动）"
      FAILED=1
      continue
    fi
  fi
  if cp -R "$SRC/$A.app" "$DEST/"; then
    chown -R "$OWNER" "$DEST/$A.app"
    echo "✓ 已安装 $DEST/$A.app（属主 $OWNER）"
  else
    echo "✗ 复制 $A.app 失败 —— 旧包在 $PREV/$A-$STAMP.app，可手动搬回"
    FAILED=1
  fi
done

# 中枢 bootstrap 回来（用安装后的新二进制）
if [ -f "$HUB_PLIST" ] && ! launchctl print "$HUB_LABEL" >/dev/null 2>&1; then
  if launchctl bootstrap "gui/$TARGET_UID" "$HUB_PLIST" 2>/dev/null; then
    echo "✓ 中枢已重新加载（新版二进制）"
  else
    echo "⚠ 中枢 bootstrap 失败，请手动：launchctl bootstrap gui/$TARGET_UID \"$HUB_PLIST\""
  fi
fi

echo
echo "版本核对（应与仓内 build/ 一致）："
for A in Dockolate DockolateHub; do
  V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/$A.app/Contents/Info.plist" 2>/dev/null || echo '?')
  S=$(sha "$DEST/$A.app/Contents/MacOS/Dockolate")
  T=$(sha "$SRC/$A.app/Contents/MacOS/Dockolate")
  if [ "$S" = "$T" ]; then M="✓ 与仓内一致"; else M="✗ 与仓内不一致"; fi
  echo "  $A.app  版本 $V  ${S:0:12}  $M"
done
exit $FAILED
