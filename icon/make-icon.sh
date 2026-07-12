#!/usr/bin/env bash
# keycap-source.ai から Liquid Glass 対応の .icon を作り、actool でコンパイルして
# AppIcon.icns(フォールバック) と Assets.car(本体) を icon/ に書き出す。
# .icon はレイヤー構成なので、ライト/ダーク/ティント/クリアの各アピアランスは
# システムが自動生成する = ダークテーマ対応も込み。
# 依存: inkscape, imagemagick(magick), Xcode(actool)。
set -euo pipefail
cd "$(dirname "$0")"

SRC="keycap-source.ai"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# 1) AI(PDF) -> 前景レイヤー(キーキャップ / 透明背景 / 中央に余白)
inkscape --export-type=png --export-width=1024 --export-height=1024 \
  --export-filename="$W/art.png" "$SRC" 2>/dev/null
magick -size 1024x1024 xc:none \( "$W/art.png" -resize 720x720 \) \
  -gravity center -composite Assets-Keycap.png 2>/dev/null || true

# メニューバー用テンプレート画像: 白い内側を透明化し輪郭+Aだけ残す(単色マスク化に耐える)
magick "$W/art.png" -fuzz 12% -fill none -opaque white -trim +repage \
  -resize 36x36 -background none -gravity center -extent 36x36 MenuBarIcon@2x.png 2>/dev/null || true
magick MenuBarIcon@2x.png -resize 18x18 MenuBarIcon.png 2>/dev/null || true

# 2) .icon バンドル(Icon Composer 互換ソース)を組む
ICON="AppIcon.icon"; rm -rf "$ICON"; mkdir -p "$ICON/Assets"
cp Assets-Keycap.png "$ICON/Assets/Keycap.png"; rm -f Assets-Keycap.png
cat > "$ICON/icon.json" <<'JSON'
{
  "fill" : { "automatic-gradient" : "srgb:0.90,0.93,0.97,1.0" },
  "groups" : [
    {
      "layers" : [ { "image-name" : "Keycap.png", "name" : "Keycap" } ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.5 }
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
JSON

# 3) actool でコンパイル -> Assets.car(Liquid Glass 本体、macOS 26+ 用)
rm -rf "$W/out"; mkdir -p "$W/out"
xcrun actool "$ICON" --compile "$W/out" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$W/out/partial.plist" >/dev/null 2>&1
cp -f "$W/out/Assets.car" Assets.car

# 4) 従来 .icns (macOS 26 未満のフォールバック)。actool の icns は 256px までしか無く
#    大表示で粗くなる/仮アイコン化するため、ライト角丸+キーキャップから 16〜1024 のフル icns を自作。
magick -size 1024x1024 xc:none -fill white \
  -draw "roundrectangle 96,96 928,928 185,185" "$W/mask.png"
magick -size 1024x1024 gradient:'#ffffff'-'#e6ebf2' "$W/grad.png"
magick "$W/grad.png" "$W/mask.png" -alpha off -compose CopyOpacity -composite "$W/bg.png"
magick \( "$W/art.png" -resize 680x680 \) \
  \( +clone -background black -shadow 45x16+0+12 \) \
  +swap -background none -layers merge +repage "$W/cap.png"
magick "$W/bg.png" "$W/cap.png" -gravity center -composite AppIcon-1024.png
ICONSET="$W/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s        AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null 2>&1
  sips -z $((s*2)) $((s*2)) AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "生成: $(pwd)/AppIcon.icns(フル解像度), Assets.car, AppIcon-1024.png (+ AppIcon.icon ソース)"
