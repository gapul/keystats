#!/usr/bin/env bash
# keystats アンインストーラ。常駐を停止し、アプリと LaunchAgent を削除する。
# データ(DB)は消さない。完全削除したい場合は末尾のコメント参照。
set -euo pipefail
LABEL="net.gapul.keystats"
GUI_LABEL="net.gapul.keystats.gui"
LA="$HOME/Library/LaunchAgents"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$GUI_LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/net.gapul.keystats.update" 2>/dev/null || true
rm -f "$LA/$LABEL.plist" "$LA/$GUI_LABEL.plist" "$LA/net.gapul.keystats.update.plist"
rm -rf "$HOME/Applications/Keystats.app"
rm -f "$HOME/.local/bin/keystats" "$HOME/.local/bin/keystats-gui" "$HOME/.local/bin/keystats-update"

echo "アンインストール完了(データは残しています)。"
echo "データも消すなら: rm -rf \"\${XDG_DATA_HOME:-\$HOME/.local/share}/keystats\" \"\${XDG_STATE_HOME:-\$HOME/.local/state}/keystats\""
echo "入力監視の許可は システム設定 > プライバシーとセキュリティ > 入力監視 から手動で外してください。"
