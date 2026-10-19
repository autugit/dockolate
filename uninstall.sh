#!/bin/bash
# 卸载 DockStats
set -euo pipefail
APP_NAME="DockStats"
LABEL="com.tanfang.dockstats"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
rm -rf "$HOME/Applications/$APP_NAME.app"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "已卸载 DockStats（日志保留在 ~/Library/Logs/DockStats.*.log）"
