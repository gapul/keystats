import Foundation
import CoreGraphics
import AppKit
import KeystatsCore

// keystats — macOS 全キーボードの打鍵をキーコード＋アプリ単位で集計する常駐。
// 記録するのは keycode / 前面アプリ / 時刻(hour) だけ。入力テキスト本文は保存しない。

final class TapBox { var port: CFMachPort? }
// C コールバック(nonisolated)から触るため unsafe を明示。タップは main のランループに載る。
nonisolated(unsafe) var globalStore: Store?

func runDaemon() {
  let store = Store()
  globalStore = store

  let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

  let callback: CGEventTapCallBack = { _, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let refcon,
         let box = Unmanaged<AnyObject>.fromOpaque(refcon).takeUnretainedValue() as? TapBox,
         let port = box.port {
        CGEvent.tapEnable(tap: port, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    let hour = Int(Date().timeIntervalSince1970) / 3600
    globalStore?.bump(hour: hour, keycode: keycode, app: app)
    return Unmanaged.passUnretained(event)
  }

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

// MARK: - entry

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "run" {
case "run":   runDaemon()
case "top":   showTop(limit: args.count > 2 ? Int(args[2]) ?? 20 : 20)
case "apps":  showApps()
case "where": print(Paths.dbPath)
default:
  print("""
    keystats — 打鍵ヒートマップ収集
      keystats run     常駐して記録 (デフォルト)
      keystats top [N] キー別トップN
      keystats apps    アプリ別打鍵数
      keystats where   DBパス表示
    GUI は keystats-gui (別バイナリ / Keystats.app)
    """)
}
