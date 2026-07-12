import Foundation
import SQLite3

// keystats の共有コア: パス / keycode ラベル / SQLite の読み書き。
// デーモン(keystats)と GUI(KeystatsGUI)の両方から使う。

public enum Paths {
  public static let dataDir: URL = {
    let base = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/share/keystats", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }()
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
]

public func label(_ keycode: Int) -> String { keyName[keycode] ?? "kc\(keycode)" }

public struct AppCount { public let app: String; public let n: Int }

// SQLite C API 直叩き(外部依存なし)。デーモンは書き込み、GUI は読み込みに使う。
public final class Store {
  private var handle: OpaquePointer?
  private var upsert: OpaquePointer?
  private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  public init(path: String = Paths.dbPath) {
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
      FileHandle.standardError.write("DBを開けない: \(path)\n".data(using: .utf8)!)
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

  private func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
  }

  // MARK: 集計(読み取り)

  public func total() -> Int {
    var t = 0
    query("SELECT COALESCE(SUM(n),0) FROM counts;") { t = Int(sqlite3_column_int64($0, 0)) }
    return t
  }

  /// keycode -> 打鍵数
  public func perKey() -> [Int: Int] {
    var out: [Int: Int] = [:]
    query("SELECT keycode, SUM(n) FROM counts GROUP BY keycode;") {
      out[Int(sqlite3_column_int64($0, 0))] = Int(sqlite3_column_int64($0, 1))
    }
    return out
  }

  /// アプリ別打鍵数(降順)
  public func perApp() -> [AppCount] {
    var out: [AppCount] = []
    query("SELECT app, SUM(n) AS s FROM counts GROUP BY app ORDER BY s DESC;") {
      out.append(AppCount(app: String(cString: sqlite3_column_text($0, 0)),
                          n: Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }

  /// keycode トップN [(keycode, n)]
  public func topKeys(_ limit: Int) -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    query("SELECT keycode, SUM(n) AS s FROM counts GROUP BY keycode ORDER BY s DESC LIMIT \(limit);") {
      out.append((Int(sqlite3_column_int64($0, 0)), Int(sqlite3_column_int64($0, 1))))
    }
    return out
  }
}
