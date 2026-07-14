import Foundation
import CoreGraphics
import AppKit
import IOKit
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
  if recentKeyTimes.count >= peakMinKeys, let first = recentKeyTimes.first, now - first > 0 {
    peakKpm = Int(Double(recentKeyTimes.count) / (now - first) * 60)
  }
  globalStore?.bumpTyping(hour: Int(now) / 3600, activeMs: Int(gap * 1000), peakKpm: peakKpm)
}

// ⌘/⌃/⌥/fn のいずれかを伴う打鍵を「組み合わせ」として記録(Shift単独は除外)。
@inline(__always) func recordComboIfNeeded(_ keycode: Int, _ flags: CGEventFlags) {
  let shortcutMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
  guard !flags.isDisjoint(with: shortcutMods) else { return }   // ショートカット修飾なし → 通常打鍵
  var label = ""
  if flags.contains(.maskSecondaryFn) { label += "fn" }
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
        // キーボード種別(内蔵/外付けの区別)
        let kbt = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
        globalStore?.bumpKbType(hour: Int(Date().timeIntervalSince1970) / 3600, kbtype: kbt)
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
  let del = (pk[51] ?? 0) + (pk[117] ?? 0)          // Delete/Backspace + 前方削除
  let total = pk.values.reduce(0, +)
  let rate = total > 0 ? Double(del) / Double(total) * 100 : 0
  print(L10n.t("cli.speed.title"))
  print(L10n.t("cli.speed.avg", t.avgKpm))
  print(L10n.t("cli.speed.peak", t.peakKpm))
  print(L10n.t("cli.speed.active", t.activeSeconds / 60))
  print(L10n.t("cli.speed.correction", rate, del, total))
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":    runDaemon()
case "top":    showTop(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "apps":   showApps()
case "combos": showCombos(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "speed":  showSpeed()
case "where":  print(Paths.dbPath)
default:
  print(L10n.t("cli.usage"))
}
