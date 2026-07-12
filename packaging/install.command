#!/usr/bin/env bash
# Keystats インストーラ(ビルド不要)。アプリ本体は隣の .payload/Keystats.app。
# 右クリック→開く で実行(初回だけ。Gatekeeper回避)。
set -euo pipefail
cd "$(dirname "$0")"

B=$'\033[1m'; G=$'\033[32m'; C=$'\033[36m'; RED=$'\033[31m'; DIM=$'\033[2m'; R=$'\033[0m'
step() { printf "\n${B}${C}▸ %s${R}\n" "$*"; }
ok()   { printf "   ${G}✓${R} %s\n" "$*"; }

APP_SRC=".payload/Keystats.app"
APP="$HOME/Applications/Keystats.app"
LA="$HOME/Library/LaunchAgents"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
uid="$(id -u)"

clear 2>/dev/null || true
printf "${B}  ⌨  Keystats インストーラ${R}\n"
printf "  ${DIM}打鍵アナリティクス — キーコードとアプリ名だけ記録。テキスト本文は保存しません。${R}\n"
printf "  ────────────────────────────────────────────\n"

if [ ! -d "$APP_SRC" ]; then
  printf "${RED}  Keystats.app が見つかりません（zipを展開してから実行してください）${R}\n"
  read -r -p "  Enter で閉じます " _; exit 1
fi

step "アプリを配置"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
for l in net.gapul.keystats net.gapul.keystats.gui net.gapul.keystats.update; do
  launchctl bootout "gui/$uid/$l" 2>/dev/null || true
done
mkdir -p "$HOME/Applications"; rm -rf "$APP"; cp -R "$APP_SRC" "$APP"
ok "~/Applications/Keystats.app"

step "常駐サービスを登録"
mkdir -p "$LA" "$XDG_DATA/keystats" "$XDG_STATE/keystats"
xdg='  <key>EnvironmentVariables</key><dict>'"<key>XDG_DATA_HOME</key><string>$XDG_DATA</string><key>XDG_STATE_HOME</key><string>$XDG_STATE</string></dict>"
cat > "$LA/net.gapul.keystats.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.gapul.keystats</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/keystatsd</string><string>run</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>
$xdg
  <key>StandardOutPath</key><string>$XDG_STATE/keystats/keystats.log</string>
  <key>StandardErrorPath</key><string>$XDG_STATE/keystats/keystats.log</string>
</dict></plist>
PLIST
cat > "$LA/net.gapul.keystats.gui.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.gapul.keystats.gui</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/KeystatsGUI</string><string>--background</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/><key>LimitLoadToSessionType</key><string>Aqua</string>
$xdg
</dict></plist>
PLIST
cat > "$LA/net.gapul.keystats.update.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>net.gapul.keystats.update</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/Resources/keystats-update</string></array>
  <key>RunAtLoad</key><true/><key>StartInterval</key><integer>86400</integer>
  <key>StandardOutPath</key><string>$XDG_STATE/keystats/update.log</string>
  <key>StandardErrorPath</key><string>$XDG_STATE/keystats/update.log</string>
</dict></plist>
PLIST
for l in net.gapul.keystats net.gapul.keystats.gui net.gapul.keystats.update; do
  launchctl bootstrap "gui/$uid" "$LA/$l.plist" 2>/dev/null || true
done
ok "ログイン時に自動起動 / 1日1回アップデート確認"

step "起動して権限を確認"
open "$APP" 2>/dev/null || true
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
ok "メニューバーにキーのアイコンが出ます"

printf "\n${G}${B}  ✓ インストール完了${R}\n"
printf "  最後の1ステップ: 開いた ${B}「入力監視」${R} で ${B}Keystats${R} を ${B}オン${R} にしてください。\n"
printf "  ${DIM}→ オンにすると記録が始まります。統計はメニューバー→「ダッシュボードを開く」。${R}\n\n"
read -r -p "  このウィンドウは閉じて大丈夫です（Enter） " _
