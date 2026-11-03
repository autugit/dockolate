#!/bin/bash
# 卸载 /Applications 里的系统版 Dockolate（连同 LaunchAgent）。
# 状态文件（~/Library/Application Support/Dockolate）默认保留——那是你的配置与配方。
set -euo pipefail
UID_NUM="$(id -u)"
LABEL_GUI="io.github.autugit.dockolate"
LABEL_HUB="ai.local.model-hub"

echo "==> 需要管理员密码（删除 /Applications 下的 App）"
sudo -v

launchctl bootout "gui/$UID_NUM/$LABEL_GUI" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$LABEL_HUB" 2>/dev/null || true
pkill -x Dockolate 2>/dev/null || true
sleep 1

rm -f "$HOME/Library/LaunchAgents/$LABEL_GUI.plist" "$HOME/Library/LaunchAgents/$LABEL_HUB.plist"
sudo rm -rf /Applications/Dockolate.app /Applications/DockolateHub.app

echo "✅ 已删除 /Applications/Dockolate*.app 与两个 LaunchAgent"
echo "   状态文件保留在 ~/Library/Application Support/Dockolate（需要时手动删）"
echo "   回滚到旧版：把 ~/Applications/_prev 里的某个 .app 拷回 /Applications 再跑 install-system.command"
read -r -p "按回车关闭…" _ || true
