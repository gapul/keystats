import Foundation

// keystats の多言語化。外部依存なしの軽量辞書方式(CLI/GUI 共通)。
// 言語は「保存された選択 > 環境変数/システム言語 > en」の順で決まる。
// GUI はメニューから手動切替(UserDefaults 保存)、CLI は LANG などのロケールに追従。

public enum Lang: String, CaseIterable, Sendable {
  case ja, en
  public var displayName: String { self == .ja ? "日本語" : "English" }
}

// 言語の設定値。system = システム(ロケール)に追従。
public enum LangPref: String, CaseIterable, Sendable { case system, ja, en }

public enum L10n {
  private static let key = "lang"

  /// 現在の言語。プロセス起動時に解決し、GUI の切替で更新する。
  nonisolated(unsafe) public static var current: Lang = resolve()

  /// 保存された選択があればそれを、無ければシステム言語を返す。
  public static func resolve() -> Lang {
    if let saved = UserDefaults.standard.string(forKey: key), let l = Lang(rawValue: saved) { return l }
    return systemLang()
  }

  /// 環境変数(KEYSTATS_LANG/LC_ALL/LC_MESSAGES/LANG)→ ロケール優先言語 の順で判定。
  public static func systemLang() -> Lang {
    let env = ProcessInfo.processInfo.environment
    for k in ["KEYSTATS_LANG", "LC_ALL", "LC_MESSAGES", "LANG"] {
      if let v = env[k]?.lowercased(), !v.isEmpty {
        if v.hasPrefix("ja") { return .ja }
        if v.hasPrefix("en") { return .en }
      }
    }
    if let code = Locale.preferredLanguages.first?.lowercased(), code.hasPrefix("ja") { return .ja }
    return .en
  }

  /// 言語を切り替えて保存(GUI 用)。
  public static func set(_ lang: Lang) {
    current = lang
    UserDefaults.standard.set(lang.rawValue, forKey: key)
  }

  /// 現在の言語設定(system/ja/en)。保存値が Lang でなければ system 扱い。
  public static var pref: LangPref {
    LangPref(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
  }

  /// 設定(system/ja/en)を適用。system はロケールに追従。
  public static func apply(_ p: LangPref) {
    UserDefaults.standard.set(p.rawValue, forKey: key)
    current = (p == .system) ? systemLang() : (Lang(rawValue: p.rawValue) ?? systemLang())
  }

  /// キーから現在言語の文字列を引く。未定義は en → キーそのものにフォールバック。
  public static func t(_ k: String) -> String {
    guard let entry = table[k] else { return k }
    return entry[current] ?? entry[.en] ?? k
  }

  /// フォーマット文字列版(%d / %@ / %.1f など)。
  public static func t(_ k: String, _ args: CVarArg...) -> String {
    String(format: t(k), arguments: args)
  }

  /// 曜日ラベル(日曜始まり)。
  public static var weekdays: [String] {
    current == .ja ? ["日", "月", "火", "水", "木", "金", "土"]
                   : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  }

  // MARK: - 辞書本体

  static let table: [String: [Lang: String]] = [
    // --- CLI ---
    "cli.total":            [.ja: "総打鍵数: %d\n",              .en: "Total keystrokes: %d\n"],
    "cli.topKeys":          [.ja: "キー別トップ%d:",            .en: "Top %d keys:"],
    "cli.apps":             [.ja: "アプリ別打鍵数:",            .en: "Keystrokes by app:"],
    "cli.combos":           [.ja: "組み合わせキー トップ%d:",   .en: "Top %d shortcuts:"],
    "cli.speed.title":      [.ja: "入力速度",                   .en: "Typing speed"],
    "cli.weak.title":       [.ja: "苦手なキー(修正直前率):",    .en: "Weak keys (pre-correction rate):"],
    "cli.keyboards.title":  [.ja: "キーボード別:",              .en: "By keyboard:"],
    "cli.speed.avg":        [.ja: "  平均      : %d KPM (フロー中)",     .en: "  Average : %d KPM (in flow)"],
    "cli.speed.peak":       [.ja: "  ピーク    : %d KPM (最速バースト)", .en: "  Peak    : %d KPM (fastest burst)"],
    "cli.speed.active":     [.ja: "  実打鍵時間: %d 分",                 .en: "  Active  : %d min"],
    "cli.speed.correction": [.ja: "  修正率    : %.1f%% (修正%d / 総%d 打鍵)",
                             .en: "  Correct : %.1f%% (%d corrections / %d total)"],
    "cli.usage": [
      .ja: """
        keystats — 打鍵ヒートマップ収集
          keystats run        常駐して記録 (デフォルト)
          keystats top [N]    キー別トップN
          keystats apps       アプリ別打鍵数
          keystats combos [N] 組み合わせキー(ショートカット)トップN
          keystats speed      入力速度(平均/ピークKPM・実打鍵時間・修正率)
          keystats weak [N]   苦手なキー(修正の直前率トップN)
          keystats keyboards  キーボード別打鍵数(ANSI/ISO/JIS)
          keystats key <k>    キー詳細(アプリ別/修飾連携)。k=キーコード or ラベル(例: A)
          keystats app <id>   アプリ詳細(よく押すキー/速度)。id=bundle id
          keystats export [json|csv]  集計をエクスポート(標準出力)
          keystats prune <days>       days日より古いデータを削除 + VACUUM
          keystats where      DBパス表示
        GUI は keystats-gui (別バイナリ / Keystats.app)
        """,
      .en: """
        keystats — keystroke heatmap collector
          keystats run        run in background and record (default)
          keystats top [N]    top N keys
          keystats apps       keystrokes by app
          keystats combos [N] top N shortcuts
          keystats speed      typing speed (avg/peak KPM, active time, correction rate)
          keystats weak [N]   weak keys (top N by pre-correction rate)
          keystats keyboards  keystrokes by keyboard (ANSI/ISO/JIS)
          keystats key <k>    key detail (by app / with modifiers). k = keycode or label (e.g. A)
          keystats app <id>   app detail (top keys). id = bundle id
          keystats where      show DB path
        GUI is keystats-gui (separate binary / Keystats.app)
        """],

    // --- daemon ---
    "daemon.start":  [.ja: "keystats: 記録開始 (%@)\n", .en: "keystats: recording started (%@)\n"],
    "daemon.tapErr": [
      .ja: """
        イベントタップを作れませんでした。
        システム設定 > プライバシーとセキュリティ > 入力監視 で keystats を許可してください。
        許可後にもう一度起動してください。\n
        """,
      .en: """
        Failed to create the event tap.
        Allow keystats in System Settings > Privacy & Security > Input Monitoring,
        then launch it again.\n
        """],
    "db.openFail": [.ja: "DBを開けない: %@\n", .en: "Cannot open DB: %@\n"],

    // --- GUI: header / controls ---
    "app.subtitle": [.ja: "打鍵アナリティクス", .en: "Keystroke analytics"],
    "install.title": [.ja: "Keystatsをインストール", .en: "Install Keystats"],
    "install.lead": [.ja: "最初に、Keystatsをアプリケーションフォルダへ移動します。", .en: "First, move Keystats to your Applications folder."],
    "install.body": [.ja: "ここへ置くと、ダウンロードしたフォルダを片付けても記録と自動更新が止まりません。既存版が動いている場合は自動で終了して置き換えます。統計データは消えません。", .en: "This keeps recording and updates working after you clean up Downloads. A running older version is closed and replaced automatically. Your statistics are kept."],
    "install.move": [.ja: "アプリケーションへ移動", .en: "Move to Applications"],
    "install.moving": [.ja: "移動しています…", .en: "Moving…"],
    "install.failed": [.ja: "アプリケーションフォルダへ移動できませんでした。", .en: "Could not move Keystats to Applications."],
    "uninstall.title": [.ja: "Keystatsをアンインストール", .en: "Uninstall Keystats"],
    "uninstall.body": [.ja: "アプリと常駐サービスを削除します。これまでの統計データは残ります。", .en: "Remove the app and background services. Your statistics will be kept."],
    "uninstall.button": [.ja: "Keystatsをアンインストール…", .en: "Uninstall Keystats…"],
    "uninstall.confirm": [.ja: "Keystatsをアンインストールしますか？", .en: "Uninstall Keystats?"],
    "uninstall.confirmBody": [.ja: "記録とメニューバー表示を停止し、アプリを削除します。統計データは削除しません。", .en: "Recording and the menu bar app will stop, and Keystats will be removed. Statistics will not be deleted."],
    "uninstall.action": [.ja: "アンインストール", .en: "Uninstall"],
    "uninstall.failed": [.ja: "アンインストール用のファイルが見つかりません。", .en: "The uninstaller helper could not be found."],
    "alert.cancel": [.ja: "キャンセル", .en: "Cancel"],
    "onboarding.title": [.ja: "Keystatsへようこそ", .en: "Welcome to Keystats"],
    "onboarding.lead": [.ja: "あと1分で、キーボードの使い方が見えるようになります。", .en: "See how you use your keyboard in about a minute."],
    "onboarding.privacy.title": [.ja: "入力した文章は保存しません", .en: "Your typed text is never saved"],
    "onboarding.privacy.body": [.ja: "記録するのは、押したキーの種類・使用中のアプリ・時間帯だけです。", .en: "Only the key, active app, and hour are recorded."],
    "onboarding.permission.title": [.ja: "入力監視をオンにする", .en: "Turn on Input Monitoring"],
    "onboarding.permission.body": [.ja: "ボタンを押し、システム設定で「Keystats」をオンにしてください。パスワード入力中はmacOSが記録を止めます。", .en: "Open System Settings and turn on Keystats. macOS blocks recording while you enter passwords."],
    "onboarding.openSettings": [.ja: "入力監視の設定を開く", .en: "Open Input Monitoring Settings"],
    "onboarding.waiting": [.ja: "Keystatsがオンになるのを待っています…", .en: "Waiting for Keystats to be turned on…"],
    "onboarding.help.title": [.ja: "一覧に出ない・オンにしても進まない場合", .en: "Not listed, or still not detected?"],
    "onboarding.help.body": [.ja: "古いKeystatsの許可が残っていることがあります。「権限を修復」でKeystatsの入力監視だけをリセットし、開き直した設定でオンにしてください。統計データは消えません。", .en: "An older Keystats permission may be stuck. Repair resets Input Monitoring for Keystats only. Turn it on again in the reopened settings. Your statistics are not deleted."],
    "onboarding.help.repair": [.ja: "権限を修復して設定を開き直す", .en: "Repair Permission and Reopen Settings"],
    "onboarding.help.failed": [.ja: "権限をリセットできませんでした。システム設定の入力監視でKeystatsを一度削除し、アプリを開き直してください。", .en: "The permission could not be reset. Remove Keystats from Input Monitoring in System Settings, then reopen the app."],
    "onboarding.ready.title": [.ja: "準備ができました", .en: "You're all set"],
    "onboarding.ready.body": [.ja: "記録は自動で始まり、メニューバーのキーアイコンからいつでも確認できます。", .en: "Recording starts automatically. Check your stats anytime from the keyboard icon in the menu bar."],
    "onboarding.start": [.ja: "ダッシュボードを見る", .en: "View Dashboard"],
    "live.on":      [.ja: "ライブ",   .en: "Live"],
    "live.off":     [.ja: "停止中",   .en: "Paused"],
    "period.today": [.ja: "今日",     .en: "Today"],
    "period.week":  [.ja: "今週",     .en: "This week"],
    "period.all":   [.ja: "全期間",   .en: "All time"],

    // --- GUI: stat cards ---
    "stat.total":        [.ja: "総打鍵数",       .en: "Total"],
    "stat.today":        [.ja: "今日",           .en: "Today"],
    "stat.peakHour":     [.ja: "ピーク時間帯",   .en: "Peak hour"],
    "stat.topApp":       [.ja: "よく使うアプリ", .en: "Top app"],
    "stat.avgSpeed":     [.ja: "平均速度",       .en: "Avg speed"],
    "stat.peakSpeed":    [.ja: "ピーク速度",     .en: "Peak speed"],
    "stat.activeTyping": [.ja: "実打鍵時間",     .en: "Active typing"],
    "stat.correction":   [.ja: "修正率",         .en: "Correction"],
    "sub.ofTotal":       [.ja: "全体の%@",       .en: "%@ of total"],
    "sub.hourKeys":      [.ja: "%@ 打鍵",        .en: "%@ keys"],
    "sub.distinctKeys":  [.ja: "%d 種のキー",    .en: "%d distinct keys"],
    "sub.kpmFlow":       [.ja: "KPM · フロー中", .en: "KPM · in flow"],
    "sub.kpmPeak":       [.ja: "KPM · 最速バースト", .en: "KPM · fastest burst"],
    "sub.activeReal":    [.ja: "実際に叩いた時間",   .en: "actual typing time"],
    "sub.corrections":   [.ja: "%@ 回修正",      .en: "%@ corrections"],
    "hour.fmt":          [.ja: "%d時",           .en: "%d:00"],

    // --- GUI: card titles ---
    "card.heatmap": [.ja: "キーボードヒートマップ", .en: "Keyboard heatmap"],
    "card.hourly":  [.ja: "時間帯別",              .en: "By hour"],
    "card.daily":   [.ja: "日別トレンド(14日)",    .en: "Daily trend (14d)"],
    "card.weekday": [.ja: "曜日 × 時間帯",         .en: "Weekday × hour"],
    "card.topKeys": [.ja: "よく押すキー",          .en: "Top keys"],
    "card.combos":  [.ja: "組み合わせキー",        .en: "Shortcuts"],
    "card.appKeys": [.ja: "アプリ別打鍵数",        .en: "Keystrokes by app"],
    "card.appTime": [.ja: "アプリ稼働時間",        .en: "App active time"],
    "card.kbType":  [.ja: "キーボード別",          .en: "By keyboard"],
    "card.weakKeys":[.ja: "苦手なキー",            .en: "Weak keys"],
    "detail.ofAll":     [.ja: "全体比",            .en: "% of all"],
    "detail.withMods":  [.ja: "修飾キー連携",      .en: "With modifiers"],
    "detail.sinceAdded":[.ja: "導入以降のデータ",  .en: "since added"],
    "weak.hint":        [.ja: "修正直前率",        .en: "pre-correction rate"],
    "back":             [.ja: "戻る",              .en: "Back"],

    "empty":       [.ja: "まだ記録なし",        .en: "No data yet"],
    "app.unknown": [.ja: "不明",                .en: "Unknown"],
    "kb.builtin":  [.ja: "内蔵/Apple (%d)",     .en: "Built-in/Apple (%d)"],
    "kb.external": [.ja: "外付け (%d)",         .en: "External (%d)"],

    // --- GUI: menu ---
    "menu.open":         [.ja: "ダッシュボードを開く", .en: "Open dashboard"],
    "menu.checkUpdate":  [.ja: "アップデートを確認",   .en: "Check for updates"],
    "menu.autoUpdate":   [.ja: "自動アップデート",     .en: "Auto-update"],
    "menu.language":     [.ja: "言語",                 .en: "Language"],
    "menu.settings":     [.ja: "設定を開く",           .en: "Open settings"],
    "settings.title":    [.ja: "設定",                 .en: "Settings"],
    "settings.appearance":[.ja: "外観",                .en: "Appearance"],
    "appearance.system": [.ja: "システム",             .en: "System"],
    "appearance.light":  [.ja: "ライト",               .en: "Light"],
    "appearance.dark":   [.ja: "ダーク",               .en: "Dark"],
    "lang.system":       [.ja: "システム",             .en: "System"],
    "settings.layoutHint":    [.ja: "自動 = 実キーボードの種別やJIS専用キーの記録から判定",
                               .en: "Auto = detected from your keyboard type / JIS-only keys"],
    "settings.autoUpdateHint":[.ja: "GitHub の新しいリリースを1日1回確認して更新",
                               .en: "Check GitHub for a new release once a day and update"],
    "menu.layout":       [.ja: "キーボード配列",       .en: "Keyboard layout"],
    "layout.auto":       [.ja: "自動",                 .en: "Auto"],
    "layout.ansi":       [.ja: "ANSI (US)",            .en: "ANSI (US)"],
    "layout.jis":        [.ja: "JIS (日本語)",         .en: "JIS (Japanese)"],
    "menu.quit":         [.ja: "keystats を終了",      .en: "Quit keystats"],

    // --- GUI: alerts ---
    "alert.ok":              [.ja: "OK",       .en: "OK"],
    "alert.later":           [.ja: "あとで",   .en: "Later"],
    "update.checkFail":      [.ja: "更新確認に失敗",           .en: "Update check failed"],
    "update.available":      [.ja: "新しいバージョンがあります", .en: "A new version is available"],
    "update.availableBody":  [.ja: "最新版に更新できます。",     .en: "You can update to the latest version."],
    "update.now":            [.ja: "今すぐ更新",               .en: "Update now"],
    "update.updatingTitle":  [.ja: "アップデート中",           .en: "Updating"],
    "update.updatingBody":   [.ja: "バックグラウンドで更新します。完了すると通知が出ます。",
                              .en: "Updating in the background. You'll be notified when done."],
    "update.latest":         [.ja: "最新版です。",             .en: "You're on the latest version."],

    // --- GUI: ダッシュボードの更新バッジ ---
    "update.checking":    [.ja: "確認中…",         .en: "Checking…"],
    "update.upToDate":    [.ja: "最新",            .en: "Latest"],
    "update.newVer":      [.ja: "アップデート %@", .en: "Update %@"],
    "update.updating":    [.ja: "更新中…",         .en: "Updating…"],
    "update.failed":      [.ja: "確認失敗",         .en: "Check failed"],
    "update.confirmBody": [.ja: "%@ に更新します。アプリが再起動します。",
                           .en: "Update to %@. The app will restart."],
  ]
}
