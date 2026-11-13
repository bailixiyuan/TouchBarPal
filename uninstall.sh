#!/bin/bash
#
# Removes TouchBarPal, its login item and its local data.
#
set -euo pipefail

APP="/Applications/TouchBarPal.app"
LABEL="com.local.touchbarpal"

if pgrep -x TouchBarPal >/dev/null 2>&1; then
  # Graceful quit first: the app dismisses its system-modal Touch Bar on exit.
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x TouchBarPal >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -x TouchBarPal >/dev/null 2>&1 || true
fi

/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$APP"
rm -rf "$HOME/Library/Application Support/TouchBarPal"
defaults delete "$LABEL" 2>/dev/null || true

echo "TouchBarPal 已卸载。"
echo "如已授予辅助功能权限，可在「系统设置 › 隐私与安全性 › 辅助功能」中手动移除。"
