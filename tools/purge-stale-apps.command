#!/bin/bash
# ============================================================
# 清扫 /Applications 里的 Dockolate 历史残留包
# ============================================================
# 症状：Finder「应用程序」里堆着一排 Dockolate / DockolateHub 图标，
#       名字像 _DockolateHub-1.8.3-r1.app、_Dockolate-1.8.2-replaced.app。
# 成因：早期替换流程先把旧包改名留在原地（而不是挪进 ~/Applications/_prev），
#       于是每升一次级就多一个孤儿包；这些包没有任何 LaunchAgent 引用。
# 处置：全部挪进「废纸篓」（可还原），不 rm。真身只留 Dockolate.app 与 DockolateHub.app。
#
# 用法：双击本文件（终端会要管理员密码）
#   bash tools/purge-stale-apps.command          # 真删（挪废纸篓）
#   bash tools/purge-stale-apps.command --dry-run # 只看会动哪些，不动
set -uo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

APP_DIR=/Applications
TRASH="$HOME/.Trash"
STAMP="$(date +%Y%m%d-%H%M%S)"
KEEP=("Dockolate.app" "DockolateHub.app")

# 只认「真身以外」的 Dockolate 包：_Dockolate*.app / Dockolate*.old / *.bak*
shopt -s nullglob
TARGETS=()
for p in "$APP_DIR"/_Dockolate*.app "$APP_DIR"/Dockolate*.old "$APP_DIR"/Dockolate*.bak*; do
  base="$(basename "$p")"
  skip=0
  for k in "${KEEP[@]}"; do [[ "$base" == "$k" ]] && skip=1; done
  [[ $skip -eq 0 ]] && TARGETS+=("$p")
done
shopt -u nullglob

echo "==> 扫描 $APP_DIR"
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "   ✓ 没有残留包，真身只有：${KEEP[*]}"
else
  for p in "${TARGETS[@]}"; do
    echo "   · $(basename "$p")  ($(du -sh "$p" 2>/dev/null | cut -f1), $(stat -f '%Su:%Sg' "$p"))"
  done
fi

if [[ $DRY -eq 1 ]]; then
  echo
  echo "（--dry-run：以上仅为预览，未做任何改动）"
  exit 0
fi

[[ ${#TARGETS[@]} -gt 0 ]] || exit 0

echo "==> 需要管理员密码（残留包属主是 root:wheel）"
sudo -v || { echo "❌ 没拿到管理员权限"; exit 1; }

mkdir -p "$TRASH"
FAILED=0
for p in "${TARGETS[@]}"; do
  base="$(basename "$p" .app)"
  dst="$TRASH/$base.$STAMP.app"
  if sudo mv "$p" "$dst"; then
    sudo chown -R "$(id -u)":staff "$dst" 2>/dev/null || true
    echo "   → 已移入废纸篓：$base"
  else
    echo "   ✗ 挪不动：$base"
    FAILED=1
  fi
done

echo "==> 让 Finder / 聚焦 / 启动台刷新图标缓存"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/Dockolate.app" "$APP_DIR/DockolateHub.app" >/dev/null 2>&1 || true
killall Dock 2>/dev/null || true

echo
echo "==> 结果"
ls -ld "$APP_DIR"/*Dockolate* 2>/dev/null | sed 's/^/   /'
echo
if [[ $FAILED -eq 0 ]]; then
  echo "✅ 清理完成。真身只剩 Dockolate.app / DockolateHub.app，旧的都在废纸篓（可还原）。"
else
  echo "⚠ 有包没挪走，见上。"
fi
echo
read -r -p "按回车关闭…" _ || true
exit $FAILED
