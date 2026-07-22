#!/usr/bin/env bash
# keystats を ~/.local/bin に入れて LaunchAgent として常駐させる。
set -euo pipefail
cd "$(dirname "$0")"

BIN="$HOME/.local/bin/keystats"
PLIST_SRC="net.gapul.keystats.plist"
PLIST_DST="$HOME/Library/LaunchAgents/net.gapul.keystats.plist"
LABEL="net.gapul.keystats"
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"

# XDG Base Directory(環境変数を尊重、無ければ既定)。launchd に注入して CLI と参照先を揃える。
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
mkdir -p "$XDG_DATA/keystats" "$XDG_STATE/keystats"
subst() { sed -e "s#__HOME__#$HOME#g" -e "s#__DATA__#$XDG_DATA#g" -e "s#__STATE__#$XDG_STATE#g" "$1"; }

# 署名アイデンティティ。Apple Developer Program の "Developer ID Application" を最優先
# (Gatekeeper 通過 + 公証可能、DR は Team ID 固定なので証明書更新後も入力監視が維持される)。
# 無ければ従来の10年自己署名 "Keystats Signing"(codesign/setup-signing.sh で作成)、
# さらに Apple Development にフォールバック。KEYSTATS_SIGN_ID で上書き可。
SIGN_ID="${KEYSTATS_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' '/Keystats Signing/{print $2; exit}')"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/{print $2; exit}')"

# Developer ID なら hardened runtime + セキュアタイムスタンプ(公証の前提)。自己署名は
# タイムスタンプ不可なので従来通り --timestamp=none。
case "$SIGN_ID" in
  *"Developer ID"*) SIGN_OPTS=(--options runtime --timestamp) ;;
  *)                SIGN_OPTS=(--timestamp=none) ;;
esac

sign() {  # sign <path> [identifier]
  [ -n "$SIGN_ID" ] || { echo "   (署名IDなし: 署名をスキップ。再ビルドで権限が外れます)"; return 0; }
  codesign --force --sign "$SIGN_ID" "${SIGN_OPTS[@]}" \
    ${2:+--identifier "$2"} "$1" >/dev/null 2>&1 \
    && echo "   signed: $(basename "$1")" || echo "   署名失敗: $(basename "$1")"
}

echo "==> build (release)"
swift build -c release
echo "==> codesign ($( [ -n "$SIGN_ID" ] && echo "$SIGN_ID" || echo none ))"
sign .build/release/keystats    net.gapul.keystats
sign .build/release/KeystatsGUI net.gapul.keystats.gui

echo "==> install CLI -> ~/.local/bin"
# CLI(top/apps/combos)は読み取り専用で入力監視不要。記録デーモンは Keystats.app 内から動かす。
mkdir -p "$HOME/.local/bin"
cp -f .build/release/keystats    "$BIN"
cp -f .build/release/KeystatsGUI "$HOME/.local/bin/keystats-gui"

echo "==> build Keystats.app -> ~/Applications"
APP="$HOME/Applications/Keystats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f .build/release/KeystatsGUI "$APP/Contents/MacOS/KeystatsGUI"
# 記録デーモンもバンドル内に置く(入力監視の一覧にアプリのアイコン/名前で出る)
cp -f .build/release/keystats "$APP/Contents/MacOS/keystatsd"
# macOS 13以降で一貫して表示できるフル解像度icns。
cp -f icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# メニューバー用テンプレート画像(アプリアイコン流用)
[ -f icon/MenuBarIcon.png ]    && cp -f icon/MenuBarIcon.png    "$APP/Contents/Resources/MenuBarIcon.png"
[ -f icon/MenuBarIcon@2x.png ] && cp -f icon/MenuBarIcon@2x.png "$APP/Contents/Resources/MenuBarIcon@2x.png"
# 自己アップデータ(バンドル同梱: 更新時に一緒に更新される)
cp -f packaging/keystats-update "$APP/Contents/Resources/keystats-update"
chmod +x "$APP/Contents/Resources/keystats-update"
cp -f packaging/keystats-uninstall "$APP/Contents/Resources/keystats-uninstall"
chmod +x "$APP/Contents/Resources/keystats-uninstall"
cp -f packaging/keystats-update "$HOME/.local/bin/keystats-update"; chmod +x "$HOME/.local/bin/keystats-update"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Keystats</string>
  <key>CFBundleIdentifier</key><string>net.gapul.keystats.gui</string>
  <key>CFBundleExecutable</key><string>KeystatsGUI</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
# .app をまとめて署名(Resources 差し替え後に)
sign "$APP"

echo "==> install LaunchAgents"
mkdir -p "$HOME/Library/LaunchAgents"
subst "$PLIST_SRC" > "$PLIST_DST"
# GUI(メニューバー常駐 / ログイン起動 / --background)
GUI_LABEL="net.gapul.keystats.gui"
GUI_PLIST_DST="$HOME/Library/LaunchAgents/$GUI_LABEL.plist"
subst "net.gapul.keystats.gui.plist" > "$GUI_PLIST_DST"
# 自己アップデータ(1日1回)
UPD_LABEL="net.gapul.keystats.update"
UPD_PLIST_DST="$HOME/Library/LaunchAgents/$UPD_LABEL.plist"
subst "net.gapul.keystats.update.plist" > "$UPD_PLIST_DST"

echo "==> load"
# 記録デーモン(バンドル内バイナリを指すので入れ直す。署名が安定なので再許可は不要)
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
# メニューバーGUI(入れ替えのため一旦落として起動)
launchctl bootout "gui/$(id -u)/$GUI_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$GUI_PLIST_DST" 2>/dev/null || true
# 自己アップデータ
launchctl bootout "gui/$(id -u)/$UPD_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$UPD_PLIST_DST" 2>/dev/null || true

cat <<EOF

インストール完了。
初回は「システム設定 > プライバシーとセキュリティ > 入力監視」に
  Keystats
がアプリのアイコンで現れるので、トグルをオンにしてください。オンにしたら:

  launchctl kickstart -k gui/$(id -u)/$LABEL

で記録が始まります。確認:
  keystats top 20
  keystats apps

GUI(集計ビュー): Keystats.app をダブルクリック、or ターミナルで keystats-gui
  ※GUIは読み取り専用。入力監視の権限は不要。
EOF
