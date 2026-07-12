#!/usr/bin/env bash
# Keystats アンインストーラ。常駐を止めてアプリと LaunchAgent を削除する(データは残す)。
set -euo pipefail

B=$'\033[1m'; G=$'\033[32m'; C=$'\033[36m'; RED=$'\033[31m'; DIM=$'\033[2m'; R=$'\033[0m'
step() { printf "\n${B}${C}▸ %s${R}\n" "$*"; }
ok()   { printf "   ${G}✓${R} %s\n" "$*"; }

uid="$(id -u)"
LA="$HOME/Library/LaunchAgents"

clear 2>/dev/null || true
printf "${B}  🗑  Keystats アンインストーラ${R}\n"
printf "  ${DIM}アプリと常駐を削除します。記録データ(統計)は残します。${R}\n"
printf "  ────────────────────────────────────────────\n"
read -r -p "  続けますか？ [y/N] " ans
case "$ans" in y|Y|yes) ;; *) printf "  中止しました\n"; exit 0;; esac

step "常駐を停止"
for l in net.gapul.keystats net.gapul.keystats.gui net.gapul.keystats.update; do
  launchctl bootout "gui/$uid/$l" 2>/dev/null || true
done
ok "サービス停止"

step "ファイルを削除"
rm -f "$LA/net.gapul.keystats.plist" "$LA/net.gapul.keystats.gui.plist" "$LA/net.gapul.keystats.update.plist"
rm -rf "$HOME/Applications/Keystats.app"
rm -f "$HOME/.local/bin/keystats" "$HOME/.local/bin/keystats-gui" "$HOME/.local/bin/keystats-update"
ok "アプリ・LaunchAgent を削除"

printf "\n${G}${B}  ✓ アンインストール完了${R}\n"
printf "  ${DIM}統計データは残しています。完全に消すには:${R}\n"
printf "    rm -rf \"\${XDG_DATA_HOME:-\$HOME/.local/share}/keystats\" \"\${XDG_STATE_HOME:-\$HOME/.local/state}/keystats\"\n"
printf "  ${DIM}入力監視の許可は システム設定 > プライバシーとセキュリティ > 入力監視 から外してください。${R}\n\n"
read -r -p "  Enter で閉じます " _
