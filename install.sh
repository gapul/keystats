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

echo "==> install binaries -> ~/.local/bin"
mkdir -p "$HOME/.local/bin"
# デーモンは中身が変わった時だけ差し替える。TCC(入力監視)は cdhash に紐づくので、
# バイナリが同一なら再コピーしない＝アイコン/GUIだけ直した時に権限を巻き添えで失わない。
if [ -f "$BIN" ] && cmp -s .build/release/keystats "$BIN"; then
  echo "   keystats(daemon): 変更なし。権限維持のため差し替えスキップ"
else
  echo "   keystats(daemon): 差し替え(初回/変更あり → 入力監視の再許可が必要)"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  cp -f .build/release/keystats "$BIN"
fi
cp -f .build/release/KeystatsGUI "$HOME/.local/bin/keystats-gui"

echo "==> build Keystats.app -> ~/Applications"
APP="$HOME/Applications/Keystats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f .build/release/KeystatsGUI "$APP/Contents/MacOS/KeystatsGUI"
# Liquid Glass アイコン: Assets.car(本体) + AppIcon.icns(フォールバック)
cp -f icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f icon/Assets.car ] && cp -f icon/Assets.car "$APP/Contents/Resources/Assets.car"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Keystats</string>
  <key>CFBundleIdentifier</key><string>net.gapul.keystats.gui</string>
  <key>CFBundleExecutable</key><string>KeystatsGUI</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST

echo "==> install LaunchAgent -> $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__HOME__#$HOME#g" "$PLIST_SRC" > "$PLIST_DST"

echo "==> load"
# 既にロード済みでも失敗しないように(スキップ時は bootout してない)
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

cat <<EOF

インストール完了。
初回は「システム設定 > プライバシーとセキュリティ > 入力監視」に
  $BIN
が現れるので、トグルをオンにしてください。オンにしたら:

  launchctl kickstart -k gui/$(id -u)/$LABEL

で記録が始まります。確認:
  keystats top 20
  keystats apps

GUI(集計ビュー): Keystats.app をダブルクリック、or ターミナルで keystats-gui
  ※GUIは読み取り専用。入力監視の権限は不要。
EOF
