import Foundation
import CoreGraphics
import AppKit
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
        recordComboIfNeeded(kc, event.flags)       // 修飾付きなら組み合わせも記録
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
  FileHandle.standardError.write("keystats: 記録開始 (\(Paths.dbPath))\n".data(using: .utf8)!)
  CFRunLoopRun()
}

// MARK: - stats (CLI)

func showTop(limit: Int) {
  let store = Store()
  let total = store.total()
  print("総打鍵数: \(total)\n")
  print("キー別トップ\(limit):")
  for (kc, n) in store.topKeys(limit) {
    let pct = total > 0 ? Double(n) / Double(total) * 100 : 0
    let bar = String(repeating: "█", count: min(40, Int(pct / 2)))
    print(String(format: "  %-8@ %8d  %5.1f%%  %@", label(kc) as NSString, n, pct, bar as NSString))
  }
}

func showApps() {
  let store = Store()
  print("アプリ別打鍵数:")
  for a in store.perApp() {
    print(String(format: "  %8d  %@", a.n, a.app as NSString))
  }
}

func showCombos(limit: Int) {
  let store = Store()
  print("組み合わせキー トップ\(limit):")
  for c in store.topCombos(limit) {
    print(String(format: "  %8d  %@", c.n, c.combo as NSString))
  }
}

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":    runDaemon()
case "top":    showTop(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "apps":   showApps()
case "combos": showCombos(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "where":  print(Paths.dbPath)
default:
  print("""
    keystats — 打鍵ヒートマップ収集
      keystats run       常駐して記録 (デフォルト)
      keystats top [N]   キー別トップN
      keystats apps      アプリ別打鍵数
      keystats combos [N] 組み合わせキー(ショートカット)トップN
      keystats where     DBパス表示
    GUI は keystats-gui (別バイナリ / Keystats.app)
    """)
}
