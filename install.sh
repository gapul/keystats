#!/usr/bin/env bash
# keystats を ~/.local/bin に入れて LaunchAgent として常駐させる。
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/keystats"
PLIST_SRC="net.gapul.keystats.plist"
PLIST_DST="$HOME/Library/LaunchAgents/net.gapul.keystats.plist"
LABEL="net.gapul.keystats"

echo "==> build (release)"
swift build -c release

echo "==> install binary -> $BIN"
mkdir -p "$HOME/.local/bin"
# 稼働中なら一旦止めてから差し替え（TCC権限は cdhash に紐づくので再ビルドで要再許可）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp -f .build/release/keystats "$BIN"

echo "==> install LaunchAgent -> $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__HOME__#$HOME#g" "$PLIST_SRC" > "$PLIST_DST"

echo "==> load"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"

cat <<EOF

インストール完了。
初回は「システム設定 > プライバシーとセキュリティ > 入力監視」に
  $BIN
が現れるので、トグルをオンにしてください。オンにしたら:

  launchctl kickstart -k gui/$(id -u)/$LABEL

で記録が始まります。確認:
  keystats top 20
  keystats apps
EOF
