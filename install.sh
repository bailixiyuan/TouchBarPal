#!/bin/bash
#
# Builds and installs TouchBarPal into /Applications, then launches it.
#
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST="/Applications/TouchBarPal.app"
LABEL="com.local.touchbarpal"

quit_running_app() {
  if ! pgrep -x TouchBarPal >/dev/null 2>&1; then
    return
  fi

  # Quit through the app so it can dismiss its system-modal Touch Bar. A bare
  # `pkill` can leave a stale bar registered with the Touch Bar server, which
  # stops the next launch from presenting one.
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x TouchBarPal >/dev/null 2>&1 || break
    sleep 0.25
  done
  pkill -x TouchBarPal >/dev/null 2>&1 || true
  sleep 1
}

echo "Installing to $DEST …"
quit_running_app

rm -rf "$DEST"
cp -R ".build/TouchBarPal.app" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo
echo "已安装并启动。"
echo "菜单栏会出现一个 Touch Bar 图标；Touch Bar 上会出现「剪贴板」「应用」和最近使用的 App。"
echo "首次点击剪贴板记录时，请在「系统设置 › 隐私与安全性 › 辅助功能」中授权，才能自动粘贴。"
