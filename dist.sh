#!/usr/bin/env bash
# 配布アーカイブを作る: 署名済み Keystats.app + install/uninstall + README を zip 化。
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

# 専用10年自己署名 "Keystats Signing" を最優先(DR固定で更新後も権限維持)。無ければフォールバック。
SIGN_ID="${KEYSTATS_SIGN_ID:-$(security find-identity -p codesigning 2>/dev/null \
  | awk -F'"' '/Keystats Signing/{print $2; exit}')}"
[ -n "$SIGN_ID" ] || SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/{print $2; exit}')"
sign() { [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" --timestamp=none \
  ${2:+--identifier "$2"} "$1" >/dev/null 2>&1 || true; }

echo "==> build (release) v$VERSION"
swift build -c release
sign .build/release/keystats    net.gapul.keystats
sign .build/release/KeystatsGUI net.gapul.keystats.gui

echo "==> assemble Keystats.app"
rm -rf "$STAGE"; mkdir -p "$STAGE/.payload"       # 本体は隠しフォルダ(誤ダブルクリック防止)
APP="$STAGE/.payload/Keystats.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/KeystatsGUI "$APP/Contents/MacOS/KeystatsGUI"
cp .build/release/keystats    "$APP/Contents/MacOS/keystatsd"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f icon/Assets.car ]        && cp icon/Assets.car        "$APP/Contents/Resources/Assets.car"
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
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
sign "$APP"
codesign --verify --deep --strict "$APP" && echo "   app署名OK" || echo "   ※署名なし/検証NG"

echo "==> bundle installer (分かりやすい名前 + カスタムアイコン)"
INST="$STAGE/Keystatsをインストール.command"
UNINST="$STAGE/Keystatsをアンインストール.command"
cp packaging/install.command   "$INST"
cp packaging/uninstall.command "$UNINST"
cp packaging/README.txt        "$STAGE/お読みください.txt"
chmod +x "$INST" "$UNINST"

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
seticon "$INST"   icon/installer-icon.png
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
