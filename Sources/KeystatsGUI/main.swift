import AppKit
import SwiftUI
import KeystatsCore

// keystats-gui — SQLite を読んで打鍵ヒートマップ＋アプリ別打鍵数を表示する SwiftUI ウィンドウ。
// 読み取り専用。入力監視権限は不要(デーモン側だけが要る)。

// MARK: - キーボードレイアウト (ANSI ざっくり)

struct KeyDef { let kc: Int; let w: Double }  // w = 幅ユニット(1 = 標準キー)

let layout: [[KeyDef]] = [
  [53,122,120,99,118,96,97,98,100,101,109,103,111].map { KeyDef(kc: $0, w: 1) },
  [50,18,19,20,21,23,22,26,28,25,29,27,24].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 51, w: 1.6)],
  [KeyDef(kc: 48, w: 1.6)] + [12,13,14,15,17,16,32,34,31,35,33,30,42].map { KeyDef(kc: $0, w: 1) },
  [KeyDef(kc: 57, w: 1.8)] + [0,1,2,3,5,4,38,40,37,41,39].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 36, w: 1.8)],
  [KeyDef(kc: 56, w: 2.3)] + [6,7,8,9,11,45,46,43,47,44].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 60, w: 2.3)],
  [KeyDef(kc: 63, w: 1), KeyDef(kc: 59, w: 1), KeyDef(kc: 58, w: 1), KeyDef(kc: 55, w: 1.3),
   KeyDef(kc: 49, w: 5.6), KeyDef(kc: 54, w: 1.3), KeyDef(kc: 61, w: 1),
   KeyDef(kc: 123, w: 1), KeyDef(kc: 125, w: 1), KeyDef(kc: 126, w: 1), KeyDef(kc: 124, w: 1)],
]

// MARK: - ヒートマップ配色

func heatColor(_ n: Int, max: Int) -> Color {
  guard n > 0, max > 0 else { return emptyKey }
  let t = pow(Double(n) / Double(max), 0.5)          // 平方根で寄りを緩和
  let hue = (1 - t) * 0.62                            // 青(0.62) → 赤(0)
  return Color(hue: hue, saturation: 0.85, brightness: 0.95)
}

// ライト/ダーク追従のグレー(打鍵ゼロのキー・棒グラフの下地)
extension Color {
  static func adaptiveGray(light: Double, dark: Double) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
      let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return NSColor(white: isDark ? dark : light, alpha: 1)
    })
  }
}
let emptyKey = Color.adaptiveGray(light: 0.90, dark: 0.20)
let barTrack = Color.adaptiveGray(light: 0.88, dark: 0.26)

func shortApp(_ bundle: String) -> String {
  bundle.split(separator: ".").last.map(String.init) ?? bundle
}

// MARK: - データ

final class Model: ObservableObject {
  @Published var total = 0
  @Published var perKey: [Int: Int] = [:]
  @Published var maxKey = 0
  @Published var apps: [AppCount] = []

  func reload() {
    let store = Store()
    let pk = store.perKey()
    total = store.total()
    perKey = pk
    maxKey = pk.values.max() ?? 0
    apps = store.perApp()
  }
}

// MARK: - View

struct KeyCap: View {
  let def: KeyDef
  let n: Int
  let maxKey: Int
  static let unit: CGFloat = 46
  static let h: CGFloat = 42

  var body: some View {
    let w = Self.unit * def.w
    VStack(spacing: 1) {
      Text(label(def.kc))
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
      Text(n > 0 ? "\(n)" : "")
        .font(.system(size: 9))
        .opacity(0.85)
    }
    .frame(width: w, height: Self.h)
    .background(heatColor(n, max: maxKey))
    .foregroundStyle(keyFg)
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }

  // 打鍵ゼロ→システム標準文字色(ライト/ダーク追従)、色付き→濃淡で黒白
  private var keyFg: Color {
    guard n > 0 else { return .primary }
    return Double(n) / Double(max(maxKey, 1)) > 0.28 ? .black : .white
  }
}

struct Keyboard: View {
  let perKey: [Int: Int]
  let maxKey: Int
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(layout.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 4) {
          ForEach(Array(row.enumerated()), id: \.offset) { _, k in
            KeyCap(def: k, n: perKey[k.kc] ?? 0, maxKey: maxKey)
          }
        }
      }
    }
  }
}

struct AppsBar: View {
  let apps: [AppCount]
  var body: some View {
    let maxN = apps.first?.n ?? 1
    VStack(alignment: .leading, spacing: 6) {
      Text("アプリ別打鍵数").font(.headline)
      ForEach(Array(apps.prefix(12).enumerated()), id: \.offset) { _, a in
        HStack(spacing: 8) {
          Text(shortApp(a.app))
            .font(.system(size: 12)).frame(width: 130, alignment: .leading).lineLimit(1)
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              RoundedRectangle(cornerRadius: 4).fill(barTrack)
              RoundedRectangle(cornerRadius: 4)
                .fill(Color(hue: 0.58, saturation: 0.7, brightness: 0.9))
                .frame(width: max(2, geo.size.width * CGFloat(a.n) / CGFloat(max(maxN, 1))))
            }
          }.frame(height: 16)
          Text("\(a.n)").font(.system(size: 11, design: .monospaced))
            .frame(width: 64, alignment: .trailing)
        }
      }
    }
  }
}

struct DashboardView: View {
  @StateObject var model = Model()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("keystats").font(.system(size: 20, weight: .bold))
        Spacer()
        Text("総打鍵数 \(model.total)").font(.system(size: 14, design: .monospaced)).opacity(0.8)
        Button("更新") { model.reload() }.keyboardShortcut("r")
      }
      Keyboard(perKey: model.perKey, maxKey: model.maxKey)
      Divider()
      AppsBar(apps: model.apps)
      Spacer()
    }
    .padding(20)
    .frame(minWidth: 760, minHeight: 560)
    .onAppear { model.reload() }
  }
}

// MARK: - AppKit bootstrap (bare executable でも前面に出す)

final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "keystats"
    window.center()
    window.contentView = NSHostingView(rootView: DashboardView())
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
