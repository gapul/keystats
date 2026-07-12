# keystats

macOS で「どのキーを」「どのアプリで」「いつ(時間単位)」叩いたかを集計する常駐ツール。
全キーボード(内蔵・Keyball・外付け)を OS 層(`CGEventTap`)でまとめて拾う。

**入力テキストの本文は一切保存しない。** 記録するのは keycode とアプリの bundle id と時刻(hour)だけ。

## 仕組み

- `CGEventTap`(listenOnly) を **HID 層(`cghidEventTap`)** に張る
  → IME(SKK 等)やショートカット処理が食う前の物理キーを拾える
- `keyDown` に加え `flagsChanged` も購読 → **修飾キー(Shift/Control/Option/Command/Fn/Caps)も記録**
  修飾キーは押下ごとに1回だけ数える(押下/離しを keycode で判別)。keyDown のオートリピートは除外
- `NSWorkspace.frontmostApplication.bundleIdentifier` で前面アプリを取得
- SQLite の `counts(hour, keycode, app, n)` に UPSERT で積む(1時間粒度に集約)
- 外部依存なし。macOS 標準の `sqlite3` をリンクするだけ

> パスワード入力中(セキュア入力)は OS がタップを止めるため記録されない(仕様どおり安全側)。

DB: `~/.local/share/keystats/keystats.db`

## インストール

```sh
./install.sh
```

ビルド → `~/.local/bin/keystats` に配置 → LaunchAgent 登録まで自動。

初回だけ手動:
1. **システム設定 > プライバシーとセキュリティ > 入力監視** で `~/.local/bin/keystats` をオン
2. `launchctl kickstart -k gui/$(id -u)/net.gapul.keystats`

> 注意: TCC 権限はバイナリの cdhash に紐づくため、デーモンを再ビルドして差し替えると
> 入力監視の許可が外れ、再度オンにする必要がある。`install.sh` はデーモンの中身が
> 変わった時だけ差し替えるので、アイコンや GUI だけ直した再実行では権限は維持される。

## 使い方

```sh
keystats top 20   # キー別トップN(打鍵数・割合・バー)
keystats apps     # アプリ別打鍵数
keystats where    # DBパス
keystats run      # 手動で常駐(通常は launchd 経由)
```

### GUI

`~/Applications/Keystats.app`(ダブルクリック)または `keystats-gui`。
キーボード配列のヒートマップ(打鍵数で色付け)＋アプリ別打鍵数の棒グラフを表示。
**読み取り専用なので入力監視の権限は不要。** デーモンが書いた SQLite を読むだけ。
`更新`(⌘R)で再読み込み。

### 生SQL

集約は素の SQL なので、時間帯別やアプリ×キーのクロス集計も直接叩ける:

```sh
sqlite3 ~/.local/share/keystats/keystats.db \
  "SELECT (hour%24) h, SUM(n) FROM counts GROUP BY h ORDER BY h;"  # UTC時間帯別
```

## 停止 / アンインストール

```sh
launchctl bootout gui/$(id -u)/net.gapul.keystats
rm ~/Library/LaunchAgents/net.gapul.keystats.plist ~/.local/bin/keystats
```

## TODO / 拡張案

- 期間フィルタ(今日/今週/全期間)を GUI に追加
- アプリ「稼働時間」の記録(前面アプリを定期ポーリング)。今は打鍵数ベース
- 時間帯ヒートマップ(hour%24 × 曜日)を GUI に追加
- 内蔵キーボード vs Keyball の分離(kCGKeyboardEventKeyboardType / IOKit)
- Keyball(QMK)側のレイヤー/コンボ込みヒートマップと突き合わせ
- .app のコード署名を安定化して再ビルドでの権限外れを回避
