import Foundation
import SQLite3

// keystats の共有コア: パス / keycode ラベル / SQLite の読み書き。
// デーモン(keystats)と GUI(KeystatsGUI)の両方から使う。

public enum Paths {
  // XDG Base Directory 準拠: 環境変数があれば尊重、無ければ既定(~/.local/...)。
  private static func xdg(_ env: String, _ fallback: String) -> URL {
    if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty {
      return URL(fileURLWithPath: v, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(fallback, isDirectory: true)
  }
  private static func ensured(_ url: URL) -> URL {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  /// データ(SQLite): $XDG_DATA_HOME/keystats or ~/.local/share/keystats
  public static let dataDir: URL = ensured(xdg("XDG_DATA_HOME", ".local/share").appendingPathComponent("keystats", isDirectory: true))
  /// 状態(ログ): $XDG_STATE_HOME/keystats or ~/.local/state/keystats
  public static var stateDir: URL { ensured(xdg("XDG_STATE_HOME", ".local/state").appendingPathComponent("keystats", isDirectory: true)) }
  public static var dbPath: String { dataDir.appendingPathComponent("keystats.db").path }
}

// macOS 仮想キーコード(ANSI 前提) -> ラベル
public let keyName: [Int: String] = [
  0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",
  14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",
  26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",
  37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",
  49:"Space",50:"`",51:"Delete",53:"Esc",54:"RCmd",55:"Cmd",56:"Shift",57:"Caps",58:"Option",
  59:"Control",60:"RShift",61:"ROption",62:"RControl",63:"Fn",65:"KP.",67:"KP*",69:"KP+",
  71:"KPClear",75:"KP/",76:"KPEnter",78:"KP-",81:"KP=",82:"KP0",83:"KP1",84:"KP2",85:"KP3",
  86:"KP4",87:"KP5",88:"KP6",89:"KP7",91:"KP8",92:"KP9",96:"F5",97:"F6",98:"F7",99:"F3",
  100:"F8",101:"F9",103:"F11",105:"F13",107:"F14",109:"F10",111:"F12",113:"F15",
  114:"Help",115:"Home",116:"PageUp",117:"FwdDel",118:"F4",119:"End",120:"F2",
  121:"PageDown",122:"F1",123:"←",124:"→",125:"↓",126:"↑",
  // JIS 特有キー(ANSI 環境でも押されれば記録されるので基本辞書にも入れておく)
  93:"¥",94:"_",95:"KP,",102:"英数",104:"かな",
]

// JIS 配列で ANSI と刻印が異なるキー(キーコードは物理位置で共通、表示だけ違う)。
public let keyNameJIS: [Int: String] = [
  24:"^", 33:"@", 30:"[", 42:"]", 39:":", 93:"¥", 94:"_", 95:"KP,", 102:"英数", 104:"かな",
]

public func label(_ keycode: Int) -> String { keyName[keycode] ?? "kc\(keycode)" }

// 文字キー(苦手キー判定の対象)。文字・数字・記号のみ。修飾/Esc/Tab/Return/Delete/矢印/F/ナビ/テンキーは除外。
public let typingKeycodes: Set<Int> = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17,   // 文字 A..T
  31, 32, 34, 35, 37, 38, 40, 45, 46,                          // O U I P L J K N M
  18, 19, 20, 21, 22, 23, 25, 26, 28, 29,                      // 数字 1..0
  24, 27, 30, 33, 39, 41, 42, 43, 44, 47, 50, 93, 94,          // 記号 = - ] [ ' ; \ , / . ` ¥ _
]
public func isTypingKey(_ keycode: Int) -> Bool { typingKeycodes.contains(keycode) }

/// JIS 配列なら刻印差を反映したラベル。ヒートマップ表示用。
public func label(_ keycode: Int, jis: Bool) -> String {
  if jis, let j = keyNameJIS[keycode] { return j }
  return label(keycode)
}

/// データに JIS 専用キー(英数/かな/¥/_)の打鍵があるか(配列自動判定用)。
extension Store {
  public func hasJISKeys() -> Bool {
    var found = false
    query("SELECT 1 FROM counts WHERE keycode IN (93,94,102,104) LIMIT 1;") { _ in found = true }
    return found
  }
}

public struct AppCount { public let app: String; public let n: Int }
public struct ComboCount { public let combo: String; public let n: Int }
public struct DayCount { public let day: Int; public let n: Int }   // day = ローカル基準の epoch 日数

// 入力速度の集計値。active_ms は「連続打鍵(gap<2s)中の合計ミリ秒」、keys はその打鍵数。
public struct TypingSummary {
  public let activeMs: Int; public let keys: Int; public let peakKpm: Int
  public init(activeMs: Int, keys: Int, peakKpm: Int) {
    self.activeMs = activeMs; self.keys = keys; self.peakKpm = peakKpm
  }
  /// フロー中の平均 KPM(キー/分)。実際に叩いていた時間で割る。
  public var avgKpm: Int { activeMs > 0 ? Int(Double(keys) / (Double(activeMs) / 60_000.0)) : 0 }
  /// 実打鍵時間(秒)。
  public var activeSeconds: Int { activeMs / 1000 }
}

// SQLite C API 直叩き(外部依存なし)。デーモンは書き込み、GUI は読み込みに使う。
public final class Store {
  private var handle: OpaquePointer?
  private var upsert: OpaquePointer?
  private var comboUpsert: OpaquePointer?
  private var apptimeUpsert: OpaquePointer?
  private var kbtypeUpsert: OpaquePointer?
  private var typingUpsert: OpaquePointer?
  private var mistypeUpsert: OpaquePointer?
  private var countsKbUpsert: OpaquePointer?
  private var typingAppUpsert: OpaquePointer?
  private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  public init(path: String = Paths.dbPath) {
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
      FileHandle.standardError.write(L10n.t("db.openFail", path).data(using: .utf8)!)
      exit(1)
    }
    exec("PRAGMA journal_mode=WAL;")
    exec("PRAGMA synchronous=NORMAL;")
    exec("""
      CREATE TABLE IF NOT EXISTS counts (
        hour    INTEGER NOT NULL,
        keycode INTEGER NOT NULL,
        app     TEXT    NOT NULL,
        n       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, keycode, app)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO counts (hour, keycode, app, n) VALUES (?, ?, ?, 1)
      ON CONFLICT(hour, keycode, app) DO UPDATE SET n = n + 1;
    """, -1, &upsert, nil)
    // 組み合わせキー(ショートカット)の集計。combo は "⌘C" のような表示ラベル。
    exec("""
      CREATE TABLE IF NOT EXISTS combos (
        hour  INTEGER NOT NULL,
        combo TEXT    NOT NULL,
        app   TEXT    NOT NULL,
        n     INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, combo, app)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO combos (hour, combo, app, n) VALUES (?, ?, ?, 1)
      ON CONFLICT(hour, combo, app) DO UPDATE SET n = n + 1;
    """, -1, &comboUpsert, nil)
    // アプリ稼働時間(前面アプリの秒数)。
    exec("""
      CREATE TABLE IF NOT EXISTS apptime (
        hour    INTEGER NOT NULL,
        app     TEXT    NOT NULL,
        seconds INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, app)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO apptime (hour, app, seconds) VALUES (?, ?, ?)
      ON CONFLICT(hour, app) DO UPDATE SET seconds = seconds + excluded.seconds;
    """, -1, &apptimeUpsert, nil)
    // キーボード種別(内蔵/外付けの区別。kCGKeyboardEventKeyboardType)。
    exec("""
      CREATE TABLE IF NOT EXISTS kbtype (
        hour   INTEGER NOT NULL,
        kbtype INTEGER NOT NULL,
        n      INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, kbtype)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO kbtype (hour, kbtype, n) VALUES (?, ?, 1)
      ON CONFLICT(hour, kbtype) DO UPDATE SET n = n + 1;
    """, -1, &kbtypeUpsert, nil)
    // 入力速度。active_ms=連続打鍵中の合計ミリ秒、keys=その打鍵数、peak_kpm=その時間内の最速バースト。
    exec("""
      CREATE TABLE IF NOT EXISTS typing (
        hour      INTEGER PRIMARY KEY,
        active_ms INTEGER NOT NULL DEFAULT 0,
        keys      INTEGER NOT NULL DEFAULT 0,
        peak_kpm  INTEGER NOT NULL DEFAULT 0
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO typing (hour, active_ms, keys, peak_kpm) VALUES (?, ?, 1, ?)
      ON CONFLICT(hour) DO UPDATE SET
        active_ms = active_ms + excluded.active_ms,
        keys      = keys + 1,
        peak_kpm  = MAX(peak_kpm, excluded.peak_kpm);
    """, -1, &typingUpsert, nil)
    // 苦手キー判定: 修正(Backspace/⌘Z/⌃H)の直前キーに等比減衰の重みを配分して蓄積。
    exec("""
      CREATE TABLE IF NOT EXISTS mistype (
        hour    INTEGER NOT NULL,
        keycode INTEGER NOT NULL,
        weight  REAL    NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, keycode)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO mistype (hour, keycode, weight) VALUES (?, ?, ?)
      ON CONFLICT(hour, keycode) DO UPDATE SET weight = weight + excluded.weight;
    """, -1, &mistypeUpsert, nil)
    // キーボード別の打鍵(kbtype 次元)。既存 counts は触らず並行記録。keyboard 別ドリルダウン用。
    exec("""
      CREATE TABLE IF NOT EXISTS counts_kb (
        hour    INTEGER NOT NULL,
        keycode INTEGER NOT NULL,
        app     TEXT    NOT NULL,
        kbtype  INTEGER NOT NULL,
        n       INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, keycode, app, kbtype)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO counts_kb (hour, keycode, app, kbtype, n) VALUES (?, ?, ?, ?, 1)
      ON CONFLICT(hour, keycode, app, kbtype) DO UPDATE SET n = n + 1;
    """, -1, &countsKbUpsert, nil)
    // アプリ別の入力速度(typing の app 次元版)。アプリ詳細で平均/ピークKPMを出す。
    exec("""
      CREATE TABLE IF NOT EXISTS typing_app (
        hour      INTEGER NOT NULL,
        app       TEXT    NOT NULL,
        active_ms INTEGER NOT NULL DEFAULT 0,
        keys      INTEGER NOT NULL DEFAULT 0,
        peak_kpm  INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (hour, app)
      ) WITHOUT ROWID;
    """)
    sqlite3_prepare_v2(handle, """
      INSERT INTO typing_app (hour, app, active_ms, keys, peak_kpm) VALUES (?, ?, ?, 1, ?)
      ON CONFLICT(hour, app) DO UPDATE SET
        active_ms = active_ms + excluded.active_ms,
        keys      = keys + 1,
        peak_kpm  = MAX(peak_kpm, excluded.peak_kpm);
    """, -1, &typingAppUpsert, nil)
  }

  deinit {   // 接続とプリペアド文を必ず解放(GUIが頻繁に生成するのでリークすると fd 枯渇→open失敗)
    sqlite3_finalize(upsert)
    sqlite3_finalize(comboUpsert)
    sqlite3_finalize(apptimeUpsert)
    sqlite3_finalize(kbtypeUpsert)
    sqlite3_finalize(typingUpsert)
    sqlite3_finalize(mistypeUpsert)
    sqlite3_finalize(countsKbUpsert)
    sqlite3_finalize(typingAppUpsert)
    sqlite3_close_v2(handle)
  }

  public func exec(_ sql: String) { sqlite3_exec(handle, sql, nil, nil, nil) }

  public func bump(hour: Int, keycode: Int, app: String) {
    guard let upsert else { return }
    sqlite3_reset(upsert)
    sqlite3_bind_int64(upsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(upsert, 2, sqlite3_int64(keycode))
    sqlite3_bind_text(upsert, 3, app, -1, Store.TRANSIENT)
    sqlite3_step(upsert)
  }

  public func bumpCombo(hour: Int, combo: String, app: String) {
    guard let comboUpsert else { return }
    sqlite3_reset(comboUpsert)
    sqlite3_bind_int64(comboUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_text(comboUpsert, 2, combo, -1, Store.TRANSIENT)
    sqlite3_bind_text(comboUpsert, 3, app, -1, Store.TRANSIENT)
    sqlite3_step(comboUpsert)
  }

  public func bumpAppTime(hour: Int, app: String, seconds: Int) {
    guard let apptimeUpsert else { return }
    sqlite3_reset(apptimeUpsert)
    sqlite3_bind_int64(apptimeUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_text(apptimeUpsert, 2, app, -1, Store.TRANSIENT)
    sqlite3_bind_int64(apptimeUpsert, 3, sqlite3_int64(seconds))
    sqlite3_step(apptimeUpsert)
  }

  public func bumpKbType(hour: Int, kbtype: Int) {
    guard let kbtypeUpsert else { return }
    sqlite3_reset(kbtypeUpsert)
    sqlite3_bind_int64(kbtypeUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(kbtypeUpsert, 2, sqlite3_int64(kbtype))
    sqlite3_step(kbtypeUpsert)
  }

  /// 入力速度を記録。activeMs=前打鍵からの間隔(ms, gap<2s のみ)、peakKpm=直近バーストの瞬間速度。
  public func bumpTyping(hour: Int, activeMs: Int, peakKpm: Int) {
    guard let typingUpsert else { return }
    sqlite3_reset(typingUpsert)
    sqlite3_bind_int64(typingUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(typingUpsert, 2, sqlite3_int64(activeMs))
    sqlite3_bind_int64(typingUpsert, 3, sqlite3_int64(peakKpm))
    sqlite3_step(typingUpsert)
  }

  /// 苦手キー: 修正の直前キー(keycode)に重み weight を加算。
  public func bumpMistype(hour: Int, keycode: Int, weight: Double) {
    guard let mistypeUpsert else { return }
    sqlite3_reset(mistypeUpsert)
    sqlite3_bind_int64(mistypeUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(mistypeUpsert, 2, sqlite3_int64(keycode))
    sqlite3_bind_double(mistypeUpsert, 3, weight)
    sqlite3_step(mistypeUpsert)
  }

  /// アプリ別の入力速度を記録。
  public func bumpTypingApp(hour: Int, app: String, activeMs: Int, peakKpm: Int) {
    guard let typingAppUpsert else { return }
    sqlite3_reset(typingAppUpsert)
    sqlite3_bind_int64(typingAppUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_text(typingAppUpsert, 2, app, -1, Store.TRANSIENT)
    sqlite3_bind_int64(typingAppUpsert, 3, sqlite3_int64(activeMs))
    sqlite3_bind_int64(typingAppUpsert, 4, sqlite3_int64(peakKpm))
    sqlite3_step(typingAppUpsert)
  }

  /// hour が beforeHour 未満の古いデータを全テーブルから削除(保持期間対策)。
  public func prune(beforeHour: Int) {
    for t in ["counts", "combos", "apptime", "kbtype", "typing", "mistype", "counts_kb", "typing_app"] {
      exec("DELETE FROM \(t) WHERE hour < \(beforeHour);")
    }
  }
  public func vacuum() { exec("VACUUM;") }

  /// キーボード別の打鍵を記録(kbtype 次元)。
  public func bumpCountKb(hour: Int, keycode: Int, app: String, kbtype: Int) {
    guard let countsKbUpsert else { return }
    sqlite3_reset(countsKbUpsert)
    sqlite3_bind_int64(countsKbUpsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(countsKbUpsert, 2, sqlite3_int64(keycode))
    sqlite3_bind_text(countsKbUpsert, 3, app, -1, Store.TRANSIENT)
    sqlite3_bind_int64(countsKbUpsert, 4, sqlite3_int64(kbtype))
    sqlite3_step(countsKbUpsert)
  }

  private func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
  }

  // MARK: 集計(読み取り)。sinceHour>0 でその hour 以降に絞る(0=全期間)。

  private func since(_ h: Int) -> String { h > 0 ? " WHERE hour >= \(h)" : "" }

  public func total(sinceHour: Int = 0) -> Int {
    var t = 0
    query("SELECT COALESCE(SUM(n),0) FROM counts" + since(sinceHour) + ";") {
      t = Int(sqlite3_column_int64($0, 0))
    }
    return t
  }

  /// keycode -> 打鍵数
  public func perKey(sinceHour: Int = 0) -> [Int: Int] {
    var out: [Int: Int] = [:]
    query("SELECT keycode, SUM(n) FROM counts" + since(sinceHour) + " GROUP BY keycode;") {
      out[Int(sqlite3_column_int64($0, 0))] = Int(sqlite3_column_int64($0, 1))
    }
    return out
  }

  /// アプリ別打鍵数(降順)
  public func perApp(sinceHour: Int = 0) -> [AppCount] {
    var out: [AppCount] = []
    query("SELECT app, SUM(n) AS s FROM counts" + since(sinceHour) + " GROUP BY app ORDER BY s DESC;") {
      out.append(AppCount(app: String(cString: sqlite3_column_text($0, 0)),
                          n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// keycode トップN [(keycode, n)]
  public func topKeys(_ limit: Int, sinceHour: Int = 0) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    query("SELECT keycode, SUM(n) AS s FROM counts" + since(sinceHour) + " GROUP BY keycode ORDER BY s DESC LIMIT \(limit);") {
      out.append((Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// 時間帯別(ローカル 0..23)の打鍵数。offsetHours はローカルの GMT オフセット(時)。
  public func hourly(offsetHours off: Int, sinceHour: Int = 0) -> [Int] {
    var out = Array(repeating: 0, count: 24)
    query("SELECT ((hour + \(off)) % 24 + 24) % 24 AS h, SUM(n) FROM counts" + since(sinceHour) + " GROUP BY h;") {
      let h = Int(sqlite3_column_int64($0, 0))
      if h >= 0, h < 24 { out[h] = Int(sqlite3_column_int64($0, 1)) }
    }
    return out
  }

  /// 直近 days 日の日別打鍵数(時系列昇順)。day はローカル基準の epoch 日数。
  public func daily(days: Int, offsetHours off: Int) -> [DayCount] {
    var out: [DayCount] = []
    query("SELECT (hour + \(off)) / 24 AS d, SUM(n) FROM counts GROUP BY d ORDER BY d DESC LIMIT \(days);") {
      out.append(DayCount(day: Int(sqlite3_column_int64($0, 0)), n: Int(sqlite3_column_int64($0, 1))))
    }
    return out.reversed()
  }

  /// 曜日(0=日..6=土) × 時間帯(0..23) の打鍵数マトリクス
  public func weekdayHour(offsetHours off: Int, sinceHour: Int = 0) -> [[Int]] {
    var out = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    // localDay=(hour+off)/24, weekday=(localDay+4)%7 (1970-01-01=木、日曜=0にするため+4)
    query("SELECT ((hour + \(off)) / 24 + 4) % 7 AS wd, ((hour + \(off)) % 24 + 24) % 24 AS h, SUM(n) FROM counts"
          + since(sinceHour) + " GROUP BY wd, h;") {
      let wd = Int(sqlite3_column_int64($0, 0)); let h = Int(sqlite3_column_int64($0, 1))
      if wd >= 0, wd < 7, h >= 0, h < 24 { out[wd][h] = Int(sqlite3_column_int64($0, 2)) }
    }
    return out
  }

  /// 組み合わせキー(ショートカット)トップN
  public func topCombos(_ limit: Int, sinceHour: Int = 0) -> [ComboCount] {
    var out: [ComboCount] = []
    query("SELECT combo, SUM(n) AS s FROM combos" + since(sinceHour) + " GROUP BY combo ORDER BY s DESC LIMIT \(limit);") {
      out.append(ComboCount(combo: String(cString: sqlite3_column_text($0, 0)),
                            n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// アプリ別の稼働秒数(降順)
  public func perAppTime(sinceHour: Int = 0) -> [AppCount] {
    var out: [AppCount] = []
    query("SELECT app, SUM(seconds) AS s FROM apptime" + since(sinceHour) + " GROUP BY app ORDER BY s DESC;") {
      out.append(AppCount(app: String(cString: sqlite3_column_text($0, 0)),
                          n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// 指定した組み合わせキー(例 ["⌘Z","⌃H"])の合計打鍵数。sinceHour で期間を絞る。修正率などに使う。
  public func comboCount(_ labels: [String], sinceHour: Int = 0) -> Int {
    guard !labels.isEmpty else { return 0 }
    let inList = labels.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
    let cond = "WHERE combo IN (\(inList))" + (sinceHour > 0 ? " AND hour >= \(sinceHour)" : "")
    var n = 0
    query("SELECT COALESCE(SUM(n),0) FROM combos \(cond);") { n = Int(sqlite3_column_int64($0, 0)) }
    return n
  }

  /// 入力速度の集計(平均KPM・ピーク・実打鍵時間)。app 指定で typing_app を、無指定で全体 typing を読む。
  public func typingSummary(sinceHour: Int = 0, app: String? = nil) -> TypingSummary {
    let table = app != nil ? "typing_app" : "typing"
    var conds: [String] = []
    if sinceHour > 0 { conds.append("hour >= \(sinceHour)") }
    if let app { conds.append("app = '\(sqlEsc(app))'") }
    let w = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
    var a = 0, k = 0, p = 0
    query("SELECT COALESCE(SUM(active_ms),0), COALESCE(SUM(keys),0), COALESCE(MAX(peak_kpm),0) FROM \(table)\(w);") {
      a = Int(sqlite3_column_int64($0, 0)); k = Int(sqlite3_column_int64($0, 1)); p = Int(sqlite3_column_int64($0, 2))
    }
    return TypingSummary(activeMs: a, keys: k, peakKpm: p)
  }

  // MARK: ドリルダウン用フィルタ集計(キー/アプリ/キーボード)

  private func sqlEsc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

  /// counts / counts_kb の FROM+WHERE を組む。kbtype 指定時のみ counts_kb を使う。
  private func countsFrom(_ sinceHour: Int, keycode: Int?, app: String?, kbtype: Int?) -> String {
    var conds: [String] = []
    if sinceHour > 0 { conds.append("hour >= \(sinceHour)") }
    if let keycode { conds.append("keycode = \(keycode)") }
    if let app { conds.append("app = '\(sqlEsc(app))'") }
    let table = kbtype != nil ? "counts_kb" : "counts"
    if let kbtype { conds.append("kbtype = \(kbtype)") }
    let w = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
    return "\(table)\(w)"
  }

  /// keycode -> 打鍵数(app/kbtype で絞れる)。
  public func keyCounts(sinceHour: Int = 0, app: String? = nil, kbtype: Int? = nil) -> [Int: Int] {
    var out: [Int: Int] = [:]
    query("SELECT keycode, SUM(n) FROM " + countsFrom(sinceHour, keycode: nil, app: app, kbtype: kbtype) + " GROUP BY keycode;") {
      out[Int(sqlite3_column_int64($0, 0))] = Int(sqlite3_column_int64($0, 1))
    }
    return out
  }

  /// アプリ別打鍵数(keycode/kbtype で絞れる, 降順)。
  public func appCounts(sinceHour: Int = 0, keycode: Int? = nil, kbtype: Int? = nil) -> [AppCount] {
    var out: [AppCount] = []
    query("SELECT app, SUM(n) AS s FROM " + countsFrom(sinceHour, keycode: keycode, app: nil, kbtype: kbtype) + " GROUP BY app ORDER BY s DESC;") {
      out.append(AppCount(app: String(cString: sqlite3_column_text($0, 0)), n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// 総打鍵数(任意フィルタ)。
  public func totalCounts(sinceHour: Int = 0, keycode: Int? = nil, app: String? = nil, kbtype: Int? = nil) -> Int {
    var t = 0
    query("SELECT COALESCE(SUM(n),0) FROM " + countsFrom(sinceHour, keycode: keycode, app: app, kbtype: kbtype) + ";") {
      t = Int(sqlite3_column_int64($0, 0))
    }
    return t
  }

  /// 時間帯別(0..23)。任意フィルタ。
  public func hourlyCounts(offsetHours off: Int, sinceHour: Int = 0, keycode: Int? = nil, app: String? = nil, kbtype: Int? = nil) -> [Int] {
    var out = Array(repeating: 0, count: 24)
    query("SELECT ((hour + \(off)) % 24 + 24) % 24 AS h, SUM(n) FROM " + countsFrom(sinceHour, keycode: keycode, app: app, kbtype: kbtype) + " GROUP BY h;") {
      let h = Int(sqlite3_column_int64($0, 0)); if h >= 0, h < 24 { out[h] = Int(sqlite3_column_int64($0, 1)) }
    }
    return out
  }

  /// 曜日×時間帯。任意フィルタ。
  public func weekdayCounts(offsetHours off: Int, sinceHour: Int = 0, keycode: Int? = nil, app: String? = nil, kbtype: Int? = nil) -> [[Int]] {
    var out = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    query("SELECT ((hour + \(off)) / 24 + 4) % 7 AS wd, ((hour + \(off)) % 24 + 24) % 24 AS h, SUM(n) FROM "
          + countsFrom(sinceHour, keycode: keycode, app: app, kbtype: kbtype) + " GROUP BY wd, h;") {
      let wd = Int(sqlite3_column_int64($0, 0)); let h = Int(sqlite3_column_int64($0, 1))
      if wd >= 0, wd < 7, h >= 0, h < 24 { out[wd][h] = Int(sqlite3_column_int64($0, 2)) }
    }
    return out
  }

  /// 直近 days 日の日別。任意フィルタ。
  public func dailyCounts(days: Int, offsetHours off: Int, keycode: Int? = nil, app: String? = nil, kbtype: Int? = nil) -> [DayCount] {
    var out: [DayCount] = []
    query("SELECT (hour + \(off)) / 24 AS d, SUM(n) FROM " + countsFrom(0, keycode: keycode, app: app, kbtype: kbtype)
          + " GROUP BY d ORDER BY d DESC LIMIT \(days);") {
      out.append(DayCount(day: Int(sqlite3_column_int64($0, 0)), n: Int(sqlite3_column_int64($0, 1))))
    }
    return out.reversed()
  }

  /// 全組み合わせキー(app で絞れる)。キー別の修飾連携は呼び出し側で末尾一致フィルタする。
  public func allCombos(sinceHour: Int = 0, app: String? = nil) -> [ComboCount] {
    var conds: [String] = []
    if sinceHour > 0 { conds.append("hour >= \(sinceHour)") }
    if let app { conds.append("app = '\(sqlEsc(app))'") }
    let w = conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND ")
    var out: [ComboCount] = []
    query("SELECT combo, SUM(n) AS s FROM combos\(w) GROUP BY combo ORDER BY s DESC;") {
      out.append(ComboCount(combo: String(cString: sqlite3_column_text($0, 0)), n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// 苦手キー: keycode -> 修正直前の重み合計。
  public func mistypeCounts(sinceHour: Int = 0) -> [Int: Double] {
    var out: [Int: Double] = [:]
    query("SELECT keycode, SUM(weight) FROM mistype" + (sinceHour > 0 ? " WHERE hour >= \(sinceHour)" : "") + " GROUP BY keycode;") {
      out[Int(sqlite3_column_int64($0, 0))] = sqlite3_column_double($0, 1)
    }
    return out
  }

  /// キーボード種別ごとの打鍵数(降順)。kbtype は kCGKeyboardEventKeyboardType。
  public func perKbType(sinceHour: Int = 0) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    query("SELECT kbtype, SUM(n) AS s FROM kbtype" + since(sinceHour) + " GROUP BY kbtype ORDER BY s DESC;") {
      out.append((Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }
}
