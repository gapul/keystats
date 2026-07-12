#!/usr/bin/env bash
# keystats 友人向けインストーラ(ビルド不要)。同じ場所にある Keystats.app を
# ~/Applications に置いて起動するだけ。LaunchAgent 登録・入力監視の案内は
# アプリ自身が初回起動時に行う。
# ダブルクリックで実行(初回は 右クリック→開く でGatekeeper回避)。
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="./Keystats.app"
APP="$HOME/Applications/Keystats.app"

[ -d "$APP_SRC" ] || { echo "Keystats.app が見つかりません($(pwd))"; exit 1; }

echo "==> Gatekeeper 隔離属性を解除"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true

echo "==> ~/Applications へ配置"
mkdir -p "$HOME/Applications"
# 旧常駐を止めてから差し替え
launchctl bootout "gui/$(id -u)/net.gapul.keystats" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/net.gapul.keystats.gui" 2>/dev/null || true
rm -rf "$APP"
cp -R "$APP_SRC" "$APP"

echo "==> 起動(アプリが常駐登録と入力監視の案内を行います)"
open "$APP"

cat <<'EOF'

インストール完了。メニューバーにキーのアイコンが出ます。
初回は「システム設定 > プライバシーとセキュリティ > 入力監視」が開くので
"Keystats" をオンにしてください(オンにすると記録が始まります)。

  ※ keystats はキーコード・アプリ名・時刻だけを記録し、
    入力したテキスト本文は一切保存しません。
EOF
