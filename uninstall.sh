#!/bin/bash
# 卸载 Dockolate
set -euo pipefail
APP_NAME="Dockolate"
LABEL="com.dockolate.app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for pid in $(pgrep -x "$APP_NAME" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
rm -rf "$HOME/Applications/$APP_NAME.app"
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "已卸载 Dockolate（日志保留在 ~/Library/Logs/Dockolate.*.log）"
