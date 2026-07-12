import Foundation
import CoreGraphics
import AppKit
import SQLite3

// keystats — macOS 全キーボードの打鍵をキーコード＋アプリ単位で集計する常駐。
// 記録するのは「どのキーを」「どのアプリで」「いつ(時間単位)」だけ。
// 入力されたテキスト本文は一切保存しない。

// MARK: - DB path

let dataDir: URL = {
  let base = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/keystats", isDirectory: true)
  try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  return base
}()
let dbPath = dataDir.appendingPathComponent("keystats.db").path

// MARK: - SQLite (C API 直叩き / 外部依存なし)

final class DB {
  private var handle: OpaquePointer?
  private var upsert: OpaquePointer?

  init(path: String) {
    guard sqlite3_open(path, &handle) == SQLITE_OK else {
      FileHandle.standardError.write("DBを開けない: \(path)\n".data(using: .utf8)!)
      exit(1)
    }
    exec("PRAGMA journal_mode=WAL;")
    exec("PRAGMA synchronous=NORMAL;")
    // hour = unix秒/3600。(時間, キーコード, アプリ)ごとに打鍵数を積む。
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

  func exec(_ sql: String) {
    sqlite3_exec(handle, sql, nil, nil, nil)
  }

  func bump(hour: Int, keycode: Int, app: String) {
    guard let upsert else { return }
    sqlite3_reset(upsert)
    sqlite3_bind_int64(upsert, 1, sqlite3_int64(hour))
    sqlite3_bind_int64(upsert, 2, sqlite3_int64(keycode))
    sqlite3_bind_text(upsert, 3, app, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) // SQLITE_TRANSIENT
    sqlite3_step(upsert)
  }

  // 集計クエリ用の素朴なヘルパ
  func query(_ sql: String, _ row: (OpaquePointer) -> Void) {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
  }
}

// MARK: - keycode -> ラベル (macOS 仮想キーコード / ANSI 前提)

let keyName: [Int: String] = [
  0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",
  14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",
  26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",
  37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",
  49:"Space",50:"`",51:"Delete",53:"Esc",55:"Cmd",56:"Shift",57:"Caps",58:"Option",
  59:"Control",60:"RShift",61:"ROption",62:"RControl",63:"Fn",65:"KP.",67:"KP*",69:"KP+",
  71:"KPClear",75:"KP/",76:"KPEnter",78:"KP-",81:"KP=",82:"KP0",83:"KP1",84:"KP2",85:"KP3",
  86:"KP4",87:"KP5",88:"KP6",89:"KP7",91:"KP8",92:"KP9",96:"F5",97:"F6",98:"F7",99:"F3",
  100:"F8",101:"F9",103:"F11",105:"F13",107:"F14",109:"F10",111:"F12",113:"F15",
  114:"Help",115:"Home",116:"PageUp",117:"FwdDel",118:"F4",119:"End",120:"F2",
  121:"PageDown",122:"F1",123:"←",124:"→",125:"↓",126:"↑",
]

func label(_ keycode: Int) -> String { keyName[keycode] ?? "kc\(keycode)" }

// MARK: - daemon

func runDaemon() {
  let db = DB(path: dbPath)

  // keyDown のみ購読（テキストは読まず keycode だけ取る）
  let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

  let callback: CGEventTapCallBack = { _, type, event, refcon in
    // タップが無効化されたら再有効化
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let refcon = refcon {
        let tap = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue()
        if let port = (tap as? TapBox)?.port {
          CGEvent.tapEnable(tap: port, enable: true)
        }
      }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    let hour = Int(Date().timeIntervalSince1970) / 3600
    globalDB?.bump(hour: hour, keycode: keycode, app: app)
    return Unmanaged.passUnretained(event)
  }

  globalDB = db
  let box = TapBox()

  guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: Unmanaged.passUnretained(box).toOpaque()
  ) else {
    FileHandle.standardError.write("""
      イベントタップを作れませんでした。
      システム設定 > プライバシーとセキュリティ > 入力監視 で keystats を許可してください。
      許可後にもう一度起動してください。\n
      """.data(using: .utf8)!)
    exit(2)
  }
  box.port = tap

  let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  FileHandle.standardError.write("keystats: 記録開始 (\(dbPath))\n".data(using: .utf8)!)
  CFRunLoopRun()
}

final class TapBox { var port: CFMachPort? }
// C コールバック(nonisolated)から触るため unsafe を明示。
// タップは main のランループに載るので実際は main スレッドから触られる。
nonisolated(unsafe) var globalDB: DB?

// MARK: - stats

func showTop(limit: Int) {
  let db = DB(path: dbPath)
  var total = 0
  db.query("SELECT COALESCE(SUM(n),0) FROM counts;") { total = Int(sqlite3_column_int64($0, 0)) }
  print("総打鍵数: \(total)\n")
  print("キー別トップ\(limit):")
  db.query("SELECT keycode, SUM(n) AS s FROM counts GROUP BY keycode ORDER BY s DESC LIMIT \(limit);") { r in
    let kc = Int(sqlite3_column_int64(r, 0))
    let n = Int(sqlite3_column_int64(r, 1))
    let pct = total > 0 ? Double(n) / Double(total) * 100 : 0
    let bar = String(repeating: "█", count: min(40, Int(pct / 2)))
    print(String(format: "  %-8@ %8d  %5.1f%%  %@", label(kc) as NSString, n, pct, bar as NSString))
  }
}

func showApps() {
  let db = DB(path: dbPath)
  print("アプリ別打鍵数:")
  db.query("SELECT app, SUM(n) AS s FROM counts GROUP BY app ORDER BY s DESC;") { r in
    let app = String(cString: sqlite3_column_text(r, 0))
    let n = Int(sqlite3_column_int64(r, 1))
    print(String(format: "  %8d  %@", n, app as NSString))
  }
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":  runDaemon()
case "top":  showTop(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "apps": showApps()
case "where": print(dbPath)
default:
  print("""
    keystats — 打鍵ヒートマップ収集
      keystats run     常駐して記録 (デフォルト)
      keystats top [N] キー別トップN
      keystats apps    アプリ別打鍵数
      keystats where   DBパス表示
    """)
}
