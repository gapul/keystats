#!/usr/bin/env bash
# keystats 友人向けインストーラ(ビルド不要)。このファイルと同じ場所にある
# Keystats.app を ~/Applications に置き、LaunchAgent を登録する。
# ダブルクリックで実行(初回は右クリック→開く でGatekeeper回避)。
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"   # --update なら静か(パネルを開かず案内も出さない)
APP_SRC="./Keystats.app"
APP="$HOME/Applications/Keystats.app"
LABEL="net.gapul.keystats"
GUI_LABEL="net.gapul.keystats.gui"
UPD_LABEL="net.gapul.keystats.update"
LA="$HOME/Library/LaunchAgents"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE="${XDG_STATE_HOME:-$HOME/.local/state}"

echo "==> keystats をインストールします"
[ -d "$APP_SRC" ] || { echo "Keystats.app が見つかりません($(pwd))"; exit 1; }

echo "==> Gatekeeper 隔離属性を解除"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true

echo "==> ~/Applications へ配置"
mkdir -p "$HOME/Applications"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$GUI_LABEL" 2>/dev/null || true
rm -rf "$APP"
cp -R "$APP_SRC" "$APP"

echo "==> データ/状態ディレクトリ($XDG_DATA, $XDG_STATE)"
mkdir -p "$XDG_DATA/keystats" "$XDG_STATE/keystats" "$LA"

echo "==> LaunchAgent 登録"
cat > "$LA/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/keystatsd</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key><dict>
    <key>XDG_DATA_HOME</key><string>$XDG_DATA</string>
    <key>XDG_STATE_HOME</key><string>$XDG_STATE</string>
  </dict>
  <key>StandardOutPath</key><string>$XDG_STATE/keystats/keystats.log</string>
  <key>StandardErrorPath</key><string>$XDG_STATE/keystats/keystats.log</string>
</dict></plist>
PLIST

cat > "$LA/$GUI_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$GUI_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/KeystatsGUI</string><string>--background</string>
  </array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>EnvironmentVariables</key><dict>
    <key>XDG_DATA_HOME</key><string>$XDG_DATA</string>
    <key>XDG_STATE_HOME</key><string>$XDG_STATE</string>
  </dict>
</dict></plist>
PLIST

# 自己アップデータ(1日1回チェック)
cat > "$LA/$UPD_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$UPD_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/Resources/keystats-update</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>86400</integer>
  <key>StandardOutPath</key><string>$XDG_STATE/keystats/update.log</string>
  <key>StandardErrorPath</key><string>$XDG_STATE/keystats/update.log</string>
</dict></plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$GUI_LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$UPD_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA/$LABEL.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA/$GUI_LABEL.plist" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA/$UPD_LABEL.plist" 2>/dev/null || true

# 更新モードならここで終わり(パネルや案内は出さない)
if [ "$MODE" = "--update" ]; then echo "更新: 差し替え完了"; exit 0; fi

open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true

cat <<EOF

インストール完了。あと1ステップ:
「システム設定 > プライバシーとセキュリティ > 入力監視」に "Keystats" が出るので
トグルをオンにしてください。オンにしたらメニューバーに打鍵数が出て記録が始まります。

  ※ keystats は「どのキーを・どのアプリで・いつ(時間単位)」だけ記録し、
    入力したテキスト本文は一切保存しません。

メニューバーのアイコンをクリック → ダッシュボードを開く で詳しい統計が見られます。
EOF
