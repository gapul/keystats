#!/usr/bin/env bash
# 配布アーカイブを作る: 署名済み Keystats.app + uninstall + README を zip 化。
# 生成物: dist/keystats-<VERSION>-macos-<arch>.zip と その sha256。
#   ./dist.sh            … zip を作るだけ
#   ./dist.sh --release  … さらに GitHub Release を作成/更新して zip をアップロード
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
ARCH="$(uname -m)"
REPO="gapul/keystats"
STAGE="dist/keystats-$VERSION"
ZIP="dist/keystats-$VERSION-macos-$ARCH.zip"

# "Developer ID Application"(Gatekeeper通過+公証可、DRはTeam ID固定)を最優先。無ければ
# 従来の10年自己署名 "Keystats Signing"、さらに Apple Development にフォールバック。
SIGN_ID="${KEYSTATS_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' '/Keystats Signing/{print $2; exit}')"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/{print $2; exit}')"
# Developer ID は hardened runtime + セキュアタイムスタンプ(公証の前提)。自己署名は不可。
case "$SIGN_ID" in
  *"Developer ID"*) SIGN_OPTS=(--options runtime --timestamp) ;;
  *)                SIGN_OPTS=(--timestamp=none) ;;
esac
sign() { [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" "${SIGN_OPTS[@]}" \
  ${2:+--identifier "$2"} "$1" >/dev/null 2>&1 || true; }

echo "==> build (release) v$VERSION"
swift build -c release
sign .build/release/keystats    net.gapul.keystats
sign .build/release/KeystatsGUI net.gapul.keystats.gui

echo "==> assemble Keystats.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/.payload"
# Homebrew Cask が参照する従来パスは維持しつつ、Finderには直接開けるアプリを見せる。
APP="$STAGE/.payload/Keystats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KeystatsGUI "$APP/Contents/MacOS/KeystatsGUI"
cp .build/release/keystats    "$APP/Contents/MacOS/keystatsd"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f icon/MenuBarIcon.png ]   && cp icon/MenuBarIcon.png   "$APP/Contents/Resources/MenuBarIcon.png"
[ -f icon/MenuBarIcon@2x.png ]&& cp icon/MenuBarIcon@2x.png "$APP/Contents/Resources/MenuBarIcon@2x.png"
cp packaging/keystats-update "$APP/Contents/Resources/keystats-update"
chmod +x "$APP/Contents/Resources/keystats-update"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Keystats</string>
  <key>CFBundleIdentifier</key><string>net.gapul.keystats.gui</string>
  <key>CFBundleExecutable</key><string>KeystatsGUI</string>
  <!-- macOS 26のFinderでもAssets.car経由の表示が不安定なため、icnsを明示する。 -->
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
sign "$APP"
codesign --verify --deep --strict "$APP" && echo "   app署名OK" || echo "   ※署名なし/検証NG"

# ==> 公証(notarization): Developer ID 署名 かつ notarytool プロファイルがある時だけ実行。
#     公証+staple 済みなら Gatekeeper を隔離付きでも通過 = cask の no_quarantine が不要になる。
NOTARY_PROFILE="${KEYSTATS_NOTARY_PROFILE:-keystats-notary}"
case "$SIGN_ID" in *"Developer ID"*) NOTARIZE=1 ;; *) NOTARIZE=0 ;; esac
if [ "$NOTARIZE" = 1 ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "==> notarize (submit & wait: 数分かかることあり)"
  NDIR="$(mktemp -d)"; NZIP="$NDIR/Keystats.zip"
  ditto -c -k --keepParent "$APP" "$NZIP"
  xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> staple"
  xcrun stapler staple "$APP" && xcrun stapler validate "$APP" && echo "   staple OK"
  rm -rf "$NDIR"
else
  echo "==> notarize: スキップ (Developer ID 署名でない or notarytool プロファイル '$NOTARY_PROFILE' 未設定)"
fi

# 実体はCask互換の場所に保ち、zip利用者には通常のアプリとして見せる。
ln -s ".payload/Keystats.app" "$STAGE/Keystats.app"

echo "==> bundle support files"
UNINST="$STAGE/Keystatsをアンインストール.command"
cp packaging/uninstall.command "$UNINST"
cp packaging/README.txt        "$STAGE/お読みください.txt"
chmod +x "$UNINST"

# .command に Finder カスタムアイコンを付与(NSWorkspace setIcon)。
seticon() {  # seticon <file> <png>
  [ -f "$2" ] || return 0
  osascript - "$1" "$2" >/dev/null 2>&1 <<'OSA' || true
use framework "AppKit"
on run {f, p}
  set img to current application's NSImage's alloc's initWithContentsOfFile:p
  current application's NSWorkspace's sharedWorkspace's setIcon:img forFile:f options:0
end run
OSA
}
seticon "$UNINST" icon/uninstaller-icon.png

echo "==> zip"
rm -f "$ZIP"
( cd dist && ditto -c -k --sequesterRsrc --keepParent "keystats-$VERSION" "$(basename "$ZIP")" )
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "   $ZIP"
echo "   sha256: $SHA"

if [ "${1:-}" = "--release" ]; then
  echo "==> GitHub Release v$VERSION"
  if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$ZIP" -R "$REPO" --clobber
  else
    gh release create "v$VERSION" "$ZIP" -R "$REPO" \
      --title "v$VERSION" --notes "keystats v$VERSION"
  fi
  echo "   sha256(cask用): $SHA"
fi
