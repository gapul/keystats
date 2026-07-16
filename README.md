# keystats

macOS の打鍵アナリティクス。「どのキーを・どのアプリで・いつ(時間単位)」叩いたかを記録して、
キーボードのヒートマップや時間帯別の統計を見られる常駐ツール。**日本語 / 英語対応。**

**入力したテキストの本文は一切保存しません。** 記録するのは keycode(どのキーか)・アプリの
bundle id・時刻(hour)だけ。パスワード入力中(セキュア入力)は OS がタップを止めるため記録されません。

Apple Silicon / macOS 13 以降。

## インストール

### Homebrew (推奨)

```sh
brew install gapul/keystats/keystats
```

インストール後、Launchpad などから **Keystats** を一度起動 → 「システム設定 > プライバシーと
セキュリティ > 入力監視」で **Keystats** をオンにすると記録開始。メニューバーに常駐します。

> このMac(作者環境)では nix-darwin の `homebrew.casks` に宣言済み(`no_quarantine` 付き)。

### 配布物 (友人向け・ビルド不要)

[Releases](https://github.com/gapul/keystats/releases/latest) の zip をダウンロード →
展開して **「Keystatsをインストール」を右クリック→開く**。本体は隠しフォルダ `.payload` に
あり、見えるのはインストーラ/アンインストーラ/README だけ(アプリ直接起動での事故防止)。

### ソースから (開発)

```sh
./install.sh          # ビルド→署名→~/Applications/... 配置→LaunchAgent 登録
```

## 仕組み

- 記録デーモンは `CGEvent` の **HID 層(`cghidEventTap`, listenOnly)** を購読。IME(SKK)や
  ショートカット処理が食う前の物理キーを拾う。`keyDown`(通常キー)＋`flagsChanged`(修飾キー:
  Shift/Ctrl/Opt/Cmd/Fn/Caps を押下ごと1回)。オートリピートは除外。
- 修飾付き打鍵は組み合わせ(`⌘C` 等)としても記録。keyboardType で内蔵/外付けを区別。
- 前面アプリの稼働時間を5秒ごとに加算(HIDIdleTime で60秒以上アイドルは除外)。
- 入力速度は連続打鍵の間隔(gap<2秒を「フロー中」)から平均/ピークKPMと実打鍵時間を算出。
  Delete/Backspace は速度計測から除外。ピークは2秒以上の持続打鍵に限る(短い連打での暴発防止)。
- 修正率 = 修正打鍵(Backspace/前方削除 + ⌘Z + ⌃H) / 総打鍵。
- 苦手キー: 修正キーの直前タイピングに等比減衰(直前=1, 0.5, …)で重みを配分。深さ4/経過3秒/重み下限で打ち切り。
  対象は文字キーのみ(修飾/Esc/矢印等は除外)。苦手度 = 直前重み / 総打鍵。`swift test` にコアロジックのテストあり。
- SQLite に集約: `counts / combos / apptime / kbtype / typing / mistype / counts_kb`(hour 粒度で UPSERT)。外部依存なし。
  `counts_kb` はキーボード別ドリルダウン用、`mistype` は苦手キー用(いずれも導入以降のデータ)。
- **アプリ(GUI)が起動時に daemon/gui/update の LaunchAgent を自分のバンドル位置から自己登録**。
  brew 等でアプリを置くだけで動き、`/Applications` でも `~/Applications` でもパスに追従。
- 記録デーモンは `Keystats.app/Contents/MacOS/keystatsd` として起動 → 入力監視の一覧に
  「Keystats」+アプリアイコンで出る。

## 保存場所 (XDG 準拠)

- DB: `$XDG_DATA_HOME/keystats/keystats.db` (既定 `~/.local/share/keystats/`)
- ログ: `$XDG_STATE_HOME/keystats/` (既定 `~/.local/state/keystats/`)

launchd はシェル env を継承しないため、LaunchAgent に XDG を注入して CLI と参照先を統一。

## GUI

`Keystats.app`(メニューバー常駐)。メニュー→「ダッシュボードを開く」。Zenn 風の配色で:

- 期間フィルタ(今日/今週/全期間)
- 統計カード(総打鍵/今日/ピーク時間帯/よく使うアプリ)
- 入力速度・精度(平均KPM / ピークKPM / 実打鍵時間 / 修正率)
- キーボード配列ヒートマップ / 時間帯別 / 日別トレンド(14日) / 曜日×時間帯
- よく押すキー / 組み合わせキー / アプリ別打鍵数 / アプリ稼働時間 / キーボード別
- **苦手なキー**(修正の直前キーに等比減衰の重みを配分。修正直前率が高い順)
- **ドリルダウン**: キー/アプリ/キーボードをクリック → その対象で絞った詳細に潜る(戻る/さらに深掘り可)
- ヘッダーにバージョン表示＋手動アップデートボタン(最新確認→その場で更新)

キーボードは **ANSI / JIS 配列**に対応。メニュー →「キーボード配列 → 自動 / ANSI / JIS」。
自動は「データにJIS専用キー(英数/かな/¥)あり → JIS」、無ければ言語・地域(日本)から推定。
アプリ名は bundle id から NSWorkspace で実表示名に解決(例 `com.tinyspeck.slackmacgap` → Slack)。
1.5秒ごとにライブ更新(トグルで停止可)。読み取り専用なので入力監視の権限は不要。

### 設定ページ

ダッシュボード右上の ⚙️(⌘,) or メニューバー →「設定を開く」。言語 / キーボード配列(自動・ANSI・JIS) /
自動アップデート をまとめて設定(ドリルダウンと同じ「潜る」画面遷移)。

### 言語 (日本語 / English)

起動時にシステム言語を自動判定。設定ページから手動でも切替可能(UserDefaults に保存)。
CLI は `LANG` などのロケール、または `KEYSTATS_LANG=en|ja` で指定。
文言は `Sources/KeystatsCore/L10n.swift` に軽量辞書として集約(外部依存なし)。

## CLI

```sh
keystats top [N]    # キー別トップN
keystats apps       # アプリ別打鍵数
keystats combos [N] # 組み合わせキー
keystats speed      # 入力速度(平均/ピークKPM・実打鍵時間・修正率)
keystats weak [N]   # 苦手なキー(修正の直前率トップN)
keystats keyboards  # キーボード別打鍵数(ANSI/ISO/JIS)
keystats key <k>    # キー詳細(アプリ別/修飾連携)。k=キーコード or ラベル(例: A)
keystats app <id>   # アプリ詳細(よく押すキー)。id=bundle id
keystats where      # DBパス
```

生 SQL でも叩ける:

```sh
sqlite3 "$(keystats where)" "SELECT app, SUM(seconds)/60 AS min FROM apptime GROUP BY app ORDER BY min DESC LIMIT 10;"
```

## 署名 / 自動更新

- 全リリースを専用の **10年有効な自己署名証明書 "Keystats Signing"** で署名
  (`codesign/setup-signing.sh` で作成)。TCC(入力監視)は署名の指定要件に紐づくので、
  同じ証明書で署名し続ける限り**更新後も許可が維持**される。
- 公証(notarize)はしていないため、配布物は初回だけ「右クリック→開く」で Gatekeeper を回避
  (install.command が隔離属性を解除)。
- `keystats-update`(アプリ同梱)が GitHub Releases を1日1回チェックし、新しければその場で
  差し替え→アプリ再起動で自己再登録。メニュー「自動アップデート」でオフにできる。
  ダッシュボード右上のボタンからは**手動で即更新**もできる。

### 更新方法 (旧版から上げる)

リモートからの強制配信はできない(更新は各自のマシンで起動する必要がある)。止まっている場合:

- **Homebrew**: `brew update && brew upgrade --cask keystats`(nix-darwin なら `darwin-rebuild switch`)
- **zip配布**: 最新 [Release](https://github.com/gapul/keystats/releases/latest) の zip を再ダウンロード →
  「Keystatsをインストール」を**もう一度実行**(既存を bootout→上書き。壊れた updater に依存しない確実な経路)
- 一度 0.4.0+ に上がれば、ダッシュボードの更新ボタン＋日次 updater で以後は自己修復する。

## リリース (メンテナ向け)

```sh
# VERSION を更新 → コミット → タグ
./dist.sh --release          # 署名済み zip を作り GitHub Release を作成/更新
# 出た sha256 で homebrew-keystats の Casks/keystats.rb を更新
```

## アンインストール

配布物の「Keystatsをアンインストール」/ `brew uninstall --zap keystats` / `./install.sh` 環境なら
`uninstall.command` 相当。データ(`~/.local/share/keystats`)は明示的に消すまで残ります。

## TODO

- 内蔵キーボード vs Keyball の厳密な分離(現状は keyboardType による概算)
- Keyball(QMK)側のレイヤー/コンボ込みヒートマップと突き合わせ
- 公証(Apple Developer Program)で初回の「右クリック→開く」を不要に
