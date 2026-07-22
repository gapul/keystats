#!/usr/bin/env bash
# Keystats インストーラ(ビルド不要)。アプリ本体は隣の .payload/Keystats.app。
# 右クリック→開く で実行(初回だけ。Gatekeeper回避)。
set -euo pipefail
# スクリプト自身の実ディレクトリへ確実に移動(相対起動/シンボリックリンク/別cwd でも)。
SELF="$0"; case "$SELF" in /*) : ;; *) SELF="$PWD/$SELF" ;; esac
cd "$(cd "$(dirname "$SELF")" && pwd -P)"

B=$'\033[1m'; G=$'\033[32m'; C=$'\033[36m'; RED=$'\033[31m'; DIM=$'\033[2m'; R=$'\033[0m'
step() { printf "\n${B}${C}▸ %s${R}\n" "$*"; }
ok()   { printf "   ${G}✓${R} %s\n" "$*"; }
fail() { printf "\n${RED}${B}  ✗ %s${R}\n" "$*"; printf "  ${DIM}このウィンドウは閉じず、上の内容を確認してください。${R}\n"; read -r -p "  Enter で閉じます " _; exit 1; }

# 新しい配布物はアプリを直接開くだけ。これは旧版の利用者向け互換インストーラ。
APP_SRC=".payload/Keystats.app"
[ -d "$APP_SRC" ] || APP_SRC="Keystats.app"
APP="$HOME/Applications/Keystats.app"
LA="$HOME/Library/LaunchAgents"
XDG_DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
uid="$(id -u)"

clear 2>/dev/null || true
printf "${B}  ⌨  Keystats インストーラ${R}\n"
printf "  ${DIM}打鍵アナリティクス — キーコードとアプリ名だけ記録。テキスト本文は保存しません。${R}\n"
printf "  ────────────────────────────────────────────\n"

# 配布対象外の環境では、途中まで配置してから失敗する前に理由を伝える。
[ "$(uname -s)" = "Darwin" ] || fail "Keystats は macOS 専用です。"
[ "$(uname -m)" = "arm64" ] || fail "この配布版は Apple Silicon Mac 専用です。"
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$os_major" -ge 13 ] 2>/dev/null || fail "macOS 13 Ventura 以降が必要です。"

if [ ! -x "$APP_SRC/Contents/MacOS/KeystatsGUI" ] || [ ! -x "$APP_SRC/Contents/MacOS/keystatsd" ]; then
  printf "${RED}  Keystats.app が見つかりません（またはファイルが未ダウンロード）${R}\n"
  printf "  ${DIM}現在地: $(pwd)${R}\n"
  printf "  ${DIM}zip を Finder で展開し、展開先フォルダ内の「Keystatsをインストール」を実行してください。${R}\n"
  printf "  ${DIM}iCloud「デスクトップと書類」内だと中身が未ダウンロードの場合があります → フォルダを一旦ダウンロードフォルダなどに移してから実行。${R}\n"
  read -r -p "  Enter で閉じます " _; exit 1
fi

if ! codesign --verify --deep --strict "$APP_SRC" >/dev/null 2>&1; then
  fail "アプリの署名を確認できません。zip をもう一度ダウンロードして展開してください。"
fi
ok "対応環境とアプリを確認"

step "アプリを配置"
xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true
for l in net.gapul.keystats net.gapul.keystats.gui net.gapul.keystats.update; do
  launchctl bootout "gui/$uid/$l" 2>/dev/null || true
done
mkdir -p "$HOME/Applications"; rm -rf "$APP"; cp -R "$APP_SRC" "$APP"
# 配置を検証(iCloud未材料化/権限などで失敗したら黙って進めない)
if [ ! -x "$APP/Contents/MacOS/KeystatsGUI" ] || [ ! -x "$APP/Contents/MacOS/keystatsd" ]; then
  printf "${RED}  配置に失敗しました: $APP${R}\n"
  printf "  ${DIM}フォルダを別の場所(例: ~/Downloads)に移してから、もう一度実行してください。${R}\n"
  read -r -p "  Enter で閉じます " _; exit 1
fi
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
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
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
  bootstrap_err="$(mktemp -t keystats-bootstrap.XXXXXX)" || fail "一時ファイルを作成できませんでした。"
  if ! launchctl bootstrap "gui/$uid" "$LA/$l.plist" 2>"$bootstrap_err"; then
    detail="$(tr '\n' ' ' < "$bootstrap_err")"
    rm -f "$bootstrap_err"
    fail "常駐サービスを登録できませんでした ($l)。$detail"
  fi
  rm -f "$bootstrap_err"
done
ok "ログイン時に自動起動 / 1日1回アップデート確認"

step "入力監視を確認"
if "$APP/Contents/MacOS/keystatsd" permission >/dev/null 2>&1; then
  ok "入力監視は許可済み"
else
  # 最初の起動で Keystats を入力監視の一覧へ登録してから、該当パネルを開く。
  launchctl kickstart -k "gui/$uid/net.gapul.keystats" 2>/dev/null || true
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
  printf "\n  開いた ${B}「入力監視」${R} で ${B}Keystats${R} をオンにしてください。\n"
  read -r -p "  オンにしたら、ここで Enter を押してください " _
  if ! "$APP/Contents/MacOS/keystatsd" permission >/dev/null 2>&1; then
    fail "入力監視がまだオフです。Keystats のトグルを確認して、もう一度インストーラを実行してください。"
  fi
  ok "入力監視を許可"
fi

step "起動を確認"
launchctl kickstart -k "gui/$uid/net.gapul.keystats" 2>/dev/null || fail "記録サービスを起動できませんでした。"
defaults write net.gapul.keystats.gui onboarded -bool true
open "$APP" 2>/dev/null || fail "Keystats を起動できませんでした。"
sleep 1
launchctl print "gui/$uid/net.gapul.keystats" >/dev/null 2>&1 || fail "記録サービスの起動を確認できませんでした。"
launchctl print "gui/$uid/net.gapul.keystats.gui" >/dev/null 2>&1 || fail "メニューバーアプリの起動を確認できませんでした。"
ok "記録サービス / メニューバーアプリ"

printf "\n${G}${B}  ✓ インストール完了${R}\n"
printf "  記録は開始済みです。統計はメニューバー→「ダッシュボードを開く」。\n"
printf "  ${DIM}入力した文章そのものは保存されません。${R}\n\n"
read -r -p "  このウィンドウは閉じて大丈夫です（Enter） " _
