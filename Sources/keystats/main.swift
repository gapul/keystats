import Foundation
import CoreGraphics
import AppKit
import IOKit
import Carbon    // KBGetLayoutType (キーボードの ANSI/ISO/JIS 判定)
import KeystatsCore

// keystats — macOS 全キーボードの打鍵をキーコード＋アプリ単位で集計する常駐。
// 記録するのは keycode / 前面アプリ / 時刻(hour) だけ。入力テキスト本文は保存しない。

final class TapBox { var port: CFMachPort? }
// C コールバック(nonisolated)から触るため unsafe を明示。タップは main のランループに載る。
nonisolated(unsafe) var globalStore: Store?

// 修飾キー(押しても文字を生まない = flagsChanged で来る)。Caps(57)はロックキーで別扱い。
let modKeys: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
nonisolated(unsafe) var downMods: Set<Int> = []   // 押しっぱなし中の修飾キー(押下/離しの判別用)

@inline(__always) func recordKey(_ keycode: Int) {
  let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
  let hour = Int(Date().timeIntervalSince1970) / 3600
  globalStore?.bump(hour: hour, keycode: keycode, app: app)
}

// 入力速度の計測用。連続打鍵の間隔で速度を測る。
let activeGapMax = 2.0                     // これ以上空いたら「入力中」でない(考え中/離席)
let peakWindow = 5.0                       // ピーク算出の移動窓(秒)
let peakMinKeys = 5                        // ピークとみなす最小打鍵数(単発の速さをノイズ除外)
let peakMinSpan = 2.0                      // ピークは2秒以上の持続打鍵のみ(短い連打の分母極小で暴発するのを防ぐ)
let correctionKeys: Set<Int> = [51, 117]   // Delete/Backspace/前方削除は速度に含めない(修正打鍵)
nonisolated(unsafe) var lastKeyTime: Double = 0
nonisolated(unsafe) var recentKeyTimes: [Double] = []   // 移動窓に入る直近の打鍵時刻

// 前打鍵からの間隔を「アクティブ打鍵時間」として積み、移動窓でピークKPMを算出。
// 修正打鍵(Delete)は除外 = 打ち間違いの分だけ速く見えるのを防ぐ。
@inline(__always) func recordTyping(_ keycode: Int) {
  guard !correctionKeys.contains(keycode) else { return }
  let now = Date().timeIntervalSince1970
  let gap = now - lastKeyTime
  defer { lastKeyTime = now }
  guard lastKeyTime > 0, gap > 0, gap < activeGapMax else {
    recentKeyTimes = [now]                 // 初回 or 長い間 → 窓をリセット
    return
  }
  recentKeyTimes.append(now)
  let cutoff = now - peakWindow
  while let first = recentKeyTimes.first, first < cutoff { recentKeyTimes.removeFirst() }
  var peakKpm = 0
  if recentKeyTimes.count >= peakMinKeys, let first = recentKeyTimes.first {
    let span = now - first
    // 2秒以上の持続打鍵に限る = 瞬間的な連打で分母が極小になり暴発するのを防ぐ
    if span >= peakMinSpan { peakKpm = Int(Double(recentKeyTimes.count) / span * 60) }
  }
  globalStore?.bumpTyping(hour: Int(now) / 3600, activeMs: Int(gap * 1000), peakKpm: peakKpm)
}

// 苦手キー: 修正(Backspace/前方削除/⌃H/⌘Z)の直前タイピングに等比減衰の重みを配分。
// 直前=1, 2つ前=ratio, 3つ前=ratio², ... と遡る(depth まで)。「打った直後に消したキー」ほど苦手。
let mistypeRatio = 0.5
let mistypeDepth = 4
let mistypeMaxAge = 3.0    // 修正の直前とみなす最大経過秒。これより古い打鍵は苦手判定に含めない(間を空けた修正の誤爆防止)
let mistypeMinWeight = 0.05 // 重みがこれ未満になったら打ち切り
nonisolated(unsafe) var recentTyped: [(kc: Int, t: Double)] = []   // 直近のタイピングキー(末尾=最新, 時刻付き)

@inline(__always) func recordMistype(_ keycode: Int, _ flags: CGEventFlags, hour: Int, now: Double) {
  let isCmd = flags.contains(.maskCommand), isCtrl = flags.contains(.maskControl), isOpt = flags.contains(.maskAlternate)
  let isBackspaceLike = correctionKeys.contains(keycode) || (keycode == 4 && isCtrl)  // Backspace/前方削除/⌃H(1文字削除)
  let isUndo = keycode == 6 && isCmd                                                  // ⌘Z(まとめて取り消し)
  if isBackspaceLike || isUndo {
    var w = 1.0
    for e in recentTyped.reversed() {                            // 新しい順に遡る
      if now - e.t > mistypeMaxAge { break }                     // 古すぎる打鍵 → 打ち切り(時間制限)
      globalStore?.bumpMistype(hour: hour, keycode: e.kc, weight: w)
      w *= mistypeRatio
      if w < mistypeMinWeight { break }                          // 重み微小 → 打ち切り
    }
    if isUndo { recentTyped.removeAll() }                        // 取り消しは範囲不定 → 履歴クリア
    else if !recentTyped.isEmpty { recentTyped.removeLast() }    // 1文字削除 → 履歴も1つ戻す
  } else if !(isCmd || isCtrl || isOpt) && isTypingKey(keycode) {  // 文字キーのみ積む(修飾/Esc/矢印等は苦手判定から除外)
    recentTyped.append((keycode, now))
    if recentTyped.count > mistypeDepth { recentTyped.removeFirst() }
  }
}

// ⌘/⌃/⌥ のいずれかを伴う打鍵を「組み合わせ」として記録(Shift単独は除外)。
// fn は除外: macOS が矢印/ナビゲーション/F キーに常時 fn フラグを付けるため、
// これを修飾扱いすると「矢印単押し → fn→」「⌘+矢印 → fn⌘→」と誤検出される。
@inline(__always) func recordComboIfNeeded(_ keycode: Int, _ flags: CGEventFlags) {
  let shortcutMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
  guard !flags.isDisjoint(with: shortcutMods) else { return }   // ショートカット修飾なし → 通常打鍵
  var label = ""
  if flags.contains(.maskControl)     { label += "⌃" }
  if flags.contains(.maskAlternate)   { label += "⌥" }
  if flags.contains(.maskShift)       { label += "⇧" }
  if flags.contains(.maskCommand)     { label += "⌘" }
  label += KeystatsCore.label(keycode)   // 例: ⌘C, ⌘⇧P, ⌃⌥→
  let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
  let hour = Int(Date().timeIntervalSince1970) / 3600
  globalStore?.bumpCombo(hour: hour, combo: label, app: app)
}

// システム全体のアイドル秒数(HIDIdleTime)。マウスも含む最後の入力からの経過。
func systemIdleSeconds() -> Double {
  var iter: io_iterator_t = 0
  guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iter) == KERN_SUCCESS
  else { return 0 }
  defer { IOObjectRelease(iter) }
  let entry = IOIteratorNext(iter)
  guard entry != 0 else { return 0 }
  defer { IOObjectRelease(entry) }
  var props: Unmanaged<CFMutableDictionary>?
  guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
        let dict = props?.takeRetainedValue() as? [String: Any],
        let idleNs = dict["HIDIdleTime"] as? Int64 else { return 0 }
  return Double(idleNs) / 1_000_000_000.0
}

// 前面アプリの稼働時間を一定間隔で加算。60秒以上アイドルなら数えない(離席をカウントしない)。
let appTimeInterval = 5.0
func recordAppTime() {
  guard systemIdleSeconds() < 60 else { return }
  let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
  let hour = Int(Date().timeIntervalSince1970) / 3600
  globalStore?.bumpAppTime(hour: hour, app: app, seconds: Int(appTimeInterval))
}

func runDaemon() {
  let store = Store()
  globalStore = store

  // keyDown(通常キー) と flagsChanged(修飾キー) の両方を購読
  let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

  let callback: CGEventTapCallBack = { _, type, event, refcon in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let refcon,
         let box = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue() as? TapBox,
         let port = box.port {
        CGEvent.tapEnable(tap: port, enable: true)
      }
    case .keyDown:
      // 長押しのオートリピートは1打鍵として扱う(重複除外)
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        recordKey(kc)                              // 物理キーとしても数える
        recordTyping(kc)                           // 入力速度(連続打鍵の間隔)。Delete は除外
        recordComboIfNeeded(kc, event.flags)       // 修飾付きなら組み合わせも記録
        // キーボード種別 + キーボード別打鍵 + 苦手キー
        let kbt = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
        let now = Date().timeIntervalSince1970
        let hour = Int(now) / 3600
        globalStore?.bumpKbType(hour: hour, kbtype: kbt)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        globalStore?.bumpCountKb(hour: hour, keycode: kc, app: app, kbtype: kbt)
        recordMistype(kc, event.flags, hour: hour, now: now)
      }
    case .flagsChanged:
      let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
      if kc == 57 {                       // Caps Lock は押下ごとに1回
        recordKey(kc)
      } else if modKeys.contains(kc) {    // Shift/Control/Option/Command/Fn
        if downMods.contains(kc) { downMods.remove(kc) }   // 離した → 数えない
        else { downMods.insert(kc); recordKey(kc) }        // 押した → 1回
      }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  let box = TapBox()
  guard let tap = CGEvent.tapCreate(
    // HID 層で拾う: IME(SKK等)やショートカット処理が食う前の物理キーを取れる。
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: Unmanaged.passUnretained(box).toOpaque()
  ) else {
    FileHandle.standardError.write(L10n.t("daemon.tapErr").data(using: .utf8)!)
    exit(2)
  }
  box.port = tap

  let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
  CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)

  // アプリ稼働時間の定期記録(前面アプリ + 非アイドル時のみ)
  let appTimer = Timer(timeInterval: appTimeInterval, repeats: true) { _ in recordAppTime() }
  RunLoop.current.add(appTimer, forMode: .common)

  FileHandle.standardError.write(L10n.t("daemon.start", Paths.dbPath).data(using: .utf8)!)
  CFRunLoopRun()
}

// MARK: - stats (CLI)

func showTop(limit: Int) {
  let store = Store()
  let total = store.total()
  print(L10n.t("cli.total", total))
  print(L10n.t("cli.topKeys", limit))
  for (kc, n) in store.topKeys(limit) {
    let pct = total > 0 ? Double(n) / Double(total) * 100 : 0
    let bar = String(repeating: "█", count: min(40, Int(pct / 2)))
    print(String(format: "  %-8@ %8d  %5.1f%%  %@", label(kc) as NSString, n, pct, bar as NSString))
  }
}

func showApps() {
  let store = Store()
  print(L10n.t("cli.apps"))
  for a in store.perApp() {
    print(String(format: "  %8d  %@", a.n, a.app as NSString))
  }
}

func showCombos(limit: Int) {
  let store = Store()
  print(L10n.t("cli.combos", limit))
  for c in store.topCombos(limit) {
    print(String(format: "  %8d  %@", c.n, c.combo as NSString))
  }
}

func showSpeed() {
  let store = Store()
  let t = store.typingSummary()
  let pk = store.perKey()
  // 修正: Delete/Backspace + 前方削除 + 取り消し(⌘Z) + Emacs風削除(⌃H)
  let corr = (pk[51] ?? 0) + (pk[117] ?? 0) + store.comboCount(["⌘Z", "⌃H"])
  let total = pk.values.reduce(0, +)
  let rate = total > 0 ? Double(corr) / Double(total) * 100 : 0
  print(L10n.t("cli.speed.title"))
  print(L10n.t("cli.speed.avg", t.avgKpm))
  print(L10n.t("cli.speed.peak", t.peakKpm))
  print(L10n.t("cli.speed.active", t.activeSeconds / 60))
  print(L10n.t("cli.speed.correction", rate, corr, total))
}

func showWeak(limit: Int) {
  let store = Store()
  let mt = store.mistypeCounts()
  let pk = store.perKey()
  let rows = mt.compactMap { (kc, w) -> (Int, Double, Double)? in
    guard isTypingKey(kc) else { return nil }           // 文字キーのみ
    let total = pk[kc] ?? 0
    guard total >= 30 else { return nil }               // 打鍵の少ないキーはノイズ除外
    return (kc, w / Double(total) * 100, w)
  }.sorted { $0.1 > $1.1 }.prefix(limit)
  print(L10n.t("cli.weak.title"))
  if rows.isEmpty { print("  (まだデータなし / no data yet)"); return }
  for (kc, rate, w) in rows {
    print(String(format: "  %-8@ %6.2f%%  (%.0f / %d)", label(kc) as NSString, rate, w, pk[kc] ?? 0))
  }
}

func kbLayoutName(_ kbtype: Int) -> String {
  switch KBGetLayoutType(Int16(truncatingIfNeeded: kbtype)) {
  case 1_245_773_600: return "JIS"
  case 1_230_262_048: return "ISO"
  case 1_095_652_169: return "ANSI"
  default: return "?"
  }
}

func showKeyboards() {
  let store = Store()
  print(L10n.t("cli.keyboards.title"))
  for (kbt, n) in store.perKbType() {
    print(String(format: "  kbtype %-4d  %-5@  %8d", kbt, kbLayoutName(kbt) as NSString, n))
  }
}

func cliComboKey(_ combo: String) -> String {   // "⌘⇧C" → "C"
  let mods: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
  return String(combo.drop(while: { mods.contains($0) }))
}

func showKey(_ arg: String) {
  let store = Store()
  let kc: Int
  if let n = Int(arg) { kc = n }
  else if let f = keyName.first(where: { $0.value.caseInsensitiveCompare(arg) == .orderedSame })?.key { kc = f }
  else { print("unknown key: \(arg)"); return }
  print("\(label(kc)) (kc\(kc))  \(store.totalCounts(keycode: kc)) 打鍵")
  print("  アプリ別 / by app:")
  for a in store.appCounts(keycode: kc).prefix(10) {
    print(String(format: "    %8d  %@", a.n, a.app as NSString))
  }
  let combos = store.allCombos().filter { cliComboKey($0.combo) == label(kc) }
  if !combos.isEmpty {
    print("  修飾キー連携 / with modifiers:")
    for c in combos.prefix(10) { print(String(format: "    %8d  %@", c.n, c.combo as NSString)) }
  }
}

func showApp(_ bundle: String) {
  let store = Store()
  print("\(bundle)  \(store.totalCounts(app: bundle)) 打鍵")
  print("  よく押すキー / top keys:")
  for (kc, n) in store.keyCounts(app: bundle).sorted(by: { $0.value > $1.value }).prefix(15) {
    print(String(format: "    %-8@ %8d", label(kc) as NSString, n))
  }
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":    runDaemon()
case "top":    showTop(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "apps":   showApps()
case "combos": showCombos(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "speed":  showSpeed()
case "weak":   showWeak(limit: args.count > 2 ? Int(args[2]) ?? 15 : 15)
case "keyboards": showKeyboards()
case "key":    if args.count > 2 { showKey(args[2]) } else { print("usage: keystats key <keycode|label>") }
case "app":    if args.count > 2 { showApp(args[2]) } else { print("usage: keystats app <bundleid>") }
case "where":  print(Paths.dbPath)
default:
  print(L10n.t("cli.usage"))
}
