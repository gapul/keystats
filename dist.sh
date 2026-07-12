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

SIGN_ID="${KEYSTATS_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development|keystats self-signed/{print $2; exit}')}"
sign() { [ -n "$SIGN_ID" ] && codesign --force --sign "$SIGN_ID" --timestamp=none \
  ${2:+--identifier "$2"} "$1" >/dev/null 2>&1 || true; }

echo "==> build (release) v$VERSION"
swift build -c release
sign .build/release/keystats    net.gapul.keystats
sign .build/release/KeystatsGUI net.gapul.keystats.gui

echo "==> assemble Keystats.app"
rm -rf "$STAGE"; mkdir -p "$STAGE"
APP="$STAGE/Keystats.app"
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

echo "==> bundle installer"
cp packaging/install.command packaging/uninstall.command packaging/README.txt "$STAGE/"
chmod +x "$STAGE/install.command" "$STAGE/uninstall.command"

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
