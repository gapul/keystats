import AppKit
import SwiftUI
import Combine
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

// MARK: - テーマ (Zenn 風: 白基調 + #3EA8FF アクセント + 角丸カード)

extension Color {
  init(hex: UInt32) {
    self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
              green: Double((hex >> 8) & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: 1)
  }
  static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
      let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let hex = isDark ? dark : light
      return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                     green: CGFloat((hex >> 8) & 0xff) / 255,
                     blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    })
  }
}

enum Theme {
  static let accent = Color(hex: 0x3EA8FF)          // Zenn ブルー
  static let accent2 = Color(hex: 0x8B5CF6)         // 補助(組み合わせ)
  static let bg     = Color.dyn(0xF3F5F8, 0x0F1115)
  static let card   = Color.dyn(0xFFFFFF, 0x1A1D23)
  static let border = Color.dyn(0xE6E9EE, 0x2A2F37)
  static let sub    = Color.dyn(0x6B7280, 0x8A93A0)
}

let emptyKey = Color.dyn(0xEDEFF3, 0x252A31)
let barTrack = Color.dyn(0xEDEFF3, 0x22262D)

func heatColor(_ n: Int, max: Int) -> Color {
  guard n > 0, max > 0 else { return emptyKey }
  let t = pow(Double(n) / Double(max), 0.5)          // 平方根で寄りを緩和
  let hue = (1 - t) * 0.62                            // 青(0.62) → 赤(0)
  return Color(hue: hue, saturation: 0.82, brightness: 0.96)
}

// bundle id を実際のアプリ表示名に解決する。DB には bundle id しか無いので表示時に引く。
// NSWorkspace(LaunchServices)で .app を探し、CFBundleDisplayName/Name を使う。
// 解決結果はキャッシュ(GUI は main スレッドのみなので unsafe で可)。
nonisolated(unsafe) var appNameCache: [String: String] = [:]

func shortApp(_ bundle: String) -> String {
  if bundle == "unknown" || bundle.isEmpty { return L10n.t("app.unknown") }  // 言語依存なので都度
  if let cached = appNameCache[bundle] { return cached }
  let name = resolveAppName(bundle)
  appNameCache[bundle] = name
  return name
}

private func resolveAppName(_ bundle: String) -> String {
  if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
    let info = Bundle(url: url)
    if let n = (info?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        ?? (info?.infoDictionary?["CFBundleDisplayName"] as? String)
        ?? (info?.infoDictionary?["CFBundleName"] as? String), !n.isEmpty {
      return n
    }
    let fn = FileManager.default.displayName(atPath: url.path)   // 例: "Safari.app"
    return fn.hasSuffix(".app") ? String(fn.dropLast(4)) : fn
  }
  // 解決不可(未インストール/ヘルパ等) → 従来のヒューリスティック(末尾コンポーネント)
  return bundle.split(separator: ".").last.map(String.init) ?? bundle
}

func dayLabel(_ day: Int) -> String {          // day = ローカル epoch 日数 → "M/d"
  let secs = Double(day) * 86400 - Double(TimeZone.current.secondsFromGMT())
  let d = Date(timeIntervalSince1970: secs)
  let f = DateFormatter(); f.dateFormat = "M/d"
  return f.string(from: d)
}

// MARK: - 共通パーツ

struct Card<Content: View>: View {
  var title: String? = nil
  var icon: String? = nil
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        HStack(spacing: 6) {
          if let icon {
            Image(systemName: icon).foregroundStyle(Theme.accent)
              .font(.system(size: 12, weight: .semibold))
          }
          Text(title).font(.system(size: 13, weight: .semibold))
          Spacer()
        }
      }
      content()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.card)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
  }
}

struct StatCard: View {
  let label: String; let value: String; var sub: String? = nil; var accent = false
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.sub)
      Text(value).font(.system(size: 27, weight: .bold, design: .rounded))
        .foregroundStyle(accent ? Theme.accent : Color.primary).lineLimit(1).minimumScaleFactor(0.6)
      if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(Theme.sub).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Theme.card)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
  }
}

// 横棒ランキング(アプリ/組み合わせ/キー 共通)
struct BarList: View {
  let rows: [(label: String, n: Int)]
  var color: Color
  var labelWidth: CGFloat = 116
  var rounded = false
  var valueFmt: (Int) -> String = { "\($0)" }
  var body: some View {
    let maxN = max(rows.first?.n ?? 1, 1)
    VStack(spacing: 7) {
      if rows.isEmpty {
        Text(L10n.t("empty")).font(.system(size: 12)).foregroundStyle(Theme.sub)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
        HStack(spacing: 10) {
          Text(r.label)
            .font(.system(size: 12, weight: rounded ? .semibold : .regular, design: rounded ? .rounded : .default))
            .frame(width: labelWidth, alignment: .leading).lineLimit(1)
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule().fill(barTrack)
              Capsule().fill(color)
                .frame(width: max(3, geo.size.width * CGFloat(r.n) / CGFloat(maxN)))
            }
          }.frame(height: 13)
          Text(valueFmt(r.n)).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.sub).frame(width: 56, alignment: .trailing)
        }
      }
    }
  }
}

// MARK: - キーボード

struct KeyCap: View {
  let def: KeyDef
  let n: Int
  let maxKey: Int
  static let unit: CGFloat = 46
  static let h: CGFloat = 42
  var body: some View {
    let w = Self.unit * def.w
    VStack(spacing: 1) {
      Text(label(def.kc)).font(.system(size: 11, weight: .medium)).lineLimit(1)
      Text(n > 0 ? "\(n)" : "").font(.system(size: 9)).opacity(0.85)
    }
    .frame(width: w, height: Self.h)
    .background(heatColor(n, max: maxKey))
    .foregroundStyle(keyFg)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
      .strokeBorder(Theme.border.opacity(n > 0 ? 0 : 1), lineWidth: 1))
  }
  private var keyFg: Color {
    // 色付きセルは常に黒文字(明るいヒート色なので黒が読みやすい)。ゼロは控えめグレー。
    n > 0 ? .black : Theme.sub
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

// MARK: - 分析チャート

struct HourlyChart: View {          // 時間帯別(0..23, ローカル)
  let hourly: [Int]
  let peak: Int
  var body: some View {
    let maxN = max(hourly.max() ?? 1, 1)
    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: 3) {
        ForEach(0..<24, id: \.self) { h in
          RoundedRectangle(cornerRadius: 3)
            .fill(h == peak ? Theme.accent : Theme.accent.opacity(0.30))
            .frame(maxWidth: .infinity)
            .frame(height: max(2, CGFloat(hourly[h]) / CGFloat(maxN) * 110))
        }
      }.frame(height: 110)
      HStack(spacing: 3) {
        ForEach(0..<24, id: \.self) { h in
          Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 8))
            .foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
        }
      }
    }
  }
}

struct DailyTrend: View {           // 日別トレンド(直近)
  let daily: [DayCount]
  var body: some View {
    let maxN = max(daily.map { $0.n }.max() ?? 1, 1)
    HStack(alignment: .bottom, spacing: 5) {
      if daily.isEmpty {
        Text(L10n.t("empty")).font(.system(size: 12)).foregroundStyle(Theme.sub)
      }
      ForEach(Array(daily.enumerated()), id: \.offset) { i, d in
        VStack(spacing: 4) {
          Text("\(d.n)").font(.system(size: 8)).foregroundStyle(Theme.sub)
            .opacity(i == daily.count - 1 ? 1 : 0)     // 最新だけ数値表示
          RoundedRectangle(cornerRadius: 3)
            .fill(i == daily.count - 1 ? Theme.accent : Theme.accent.opacity(0.55))
            .frame(height: max(2, CGFloat(d.n) / CGFloat(maxN) * 110))
          Text(dayLabel(d.day)).font(.system(size: 8)).foregroundStyle(Theme.sub)
        }.frame(maxWidth: .infinity)
      }
    }.frame(height: 150)
  }
}

struct WeekdayHeatmap: View {       // 曜日 × 時間帯
  let grid: [[Int]]                 // [7][24]
  private var days: [String] { L10n.weekdays }
  var body: some View {
    let maxN = max(grid.flatMap { $0 }.max() ?? 1, 1)
    VStack(spacing: 2) {
      HStack(spacing: 2) {
        Text("").frame(width: 20)
        ForEach(0..<24, id: \.self) { h in
          Text(h % 6 == 0 ? "\(h)" : "").font(.system(size: 7)).foregroundStyle(Theme.sub)
            .frame(maxWidth: .infinity)
        }
      }
      ForEach(0..<7, id: \.self) { wd in
        HStack(spacing: 2) {
          Text(days[wd]).font(.system(size: 9)).foregroundStyle(Theme.sub).frame(width: 20, alignment: .leading)
          ForEach(0..<24, id: \.self) { h in
            RoundedRectangle(cornerRadius: 2).fill(cell(grid[wd][h], maxN))
              .frame(maxWidth: .infinity).frame(height: 13)
          }
        }
      }
    }
  }
  private func cell(_ n: Int, _ maxN: Int) -> Color {
    guard n > 0 else { return emptyKey }
    return Theme.accent.opacity(0.15 + 0.85 * pow(Double(n) / Double(maxN), 0.5))
  }
}

// MARK: - データ

enum Period: String, CaseIterable, Identifiable {
  case today, week, all
  var id: String { rawValue }
  var title: String {
    switch self {
    case .today: return L10n.t("period.today")
    case .week:  return L10n.t("period.week")
    case .all:   return L10n.t("period.all")
    }
  }
  var sinceHour: Int {
    let cal = Calendar.current
    switch self {
    case .all: return 0
    case .today: return Int(cal.startOfDay(for: Date()).timeIntervalSince1970) / 3600
    case .week:
      let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
      let start = cal.date(from: c) ?? cal.startOfDay(for: Date())
      return Int(start.timeIntervalSince1970) / 3600
    }
  }
}

final class Model: ObservableObject {
  @Published var period: Period = .all { didSet { reload() } }
  @Published var total = 0
  @Published var today = 0
  @Published var perKey: [Int: Int] = [:]
  @Published var maxKey = 0
  @Published var apps: [AppCount] = []
  @Published var appTime: [AppCount] = []
  @Published var combos: [ComboCount] = []
  @Published var hourly: [Int] = Array(repeating: 0, count: 24)
  @Published var daily: [DayCount] = []
  @Published var weekday: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
  @Published var topKeys: [(Int, Int)] = []
  @Published var kbTypes: [(Int, Int)] = []
  @Published var typing = TypingSummary(activeMs: 0, keys: 0, peakKpm: 0)

  private let s = Store()   // 接続を使い回す(毎回開くと fd リークで枯渇→GUIが落ちる)

  func reload() {
    let off = TimeZone.current.secondsFromGMT() / 3600
    let sh = period.sinceHour
    total = s.total()
    let startHour = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) / 3600
    today = s.total(sinceHour: startHour)
    let pk = s.perKey(sinceHour: sh)
    perKey = pk
    maxKey = pk.values.max() ?? 0
    apps = s.perApp(sinceHour: sh)
    appTime = s.perAppTime(sinceHour: sh)
    combos = s.topCombos(12, sinceHour: sh)
    hourly = s.hourly(offsetHours: off, sinceHour: sh)
    daily = s.daily(days: 14, offsetHours: off)
    weekday = s.weekdayHour(offsetHours: off, sinceHour: sh)
    topKeys = s.topKeys(12, sinceHour: sh)
    kbTypes = s.perKbType(sinceHour: sh)
    typing = s.typingSummary(sinceHour: sh)
  }

  var peakHour: Int { hourly.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0 }
  var topAppName: String { apps.first.map { shortApp($0.app) } ?? "—" }
  var distinctKeys: Int { perKey.values.filter { $0 > 0 }.count }
  // 修正打鍵(Delete/Backspace + 前方削除)。入力テキストは記録しないので打ち間違いの近似。
  var deletes: Int { (perKey[51] ?? 0) + (perKey[117] ?? 0) }
  var periodTotal: Int { perKey.values.reduce(0, +) }
  var correctionRate: Double { periodTotal > 0 ? Double(deletes) / Double(periodTotal) * 100 : 0 }
}

func fmtDuration(_ seconds: Int) -> String {
  let h = seconds / 3600, m = (seconds % 3600) / 60
  if h > 0 { return "\(h)h \(m)m" }
  if m > 0 { return "\(m)m" }
  return "\(seconds)s"
}

func kbTypeLabel(_ t: Int) -> String {
  // 代表的な内蔵キーボードの keyboardType。厳密でないので概ねの目安。
  switch t {
  case 40, 41, 42, 43, 44, 45, 46, 47: return L10n.t("kb.builtin", t)
  default: return L10n.t("kb.external", t)
  }
}

// 言語などのアプリ全体設定。切替で SwiftUI を再描画するため ObservableObject。
@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  @Published var lang: Lang = L10n.current
  func setLang(_ l: Lang) { L10n.set(l); lang = l }
}

// アプリ内アップデート(手動)。GitHub Releases の最新版を確認し、ボタンで適用する。
// 適用は同梱 keystats-update を launchd 経由で走らせる(実行中の自分を安全に差し替えるため
// GUI から切り離して動かす)。差し替え後は updater が新アプリを起動し直す。
@MainActor
final class Updater: ObservableObject {
  enum State: Equatable { case checking, upToDate, available(String), updating, failed }
  @Published var state: State = .checking
  let current: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

  /// GitHub の最新リリースを取得して現在版と比較。
  func check() {
    state = .checking
    Task {
      guard let url = URL(string: "https://api.github.com/repos/gapul/keystats/releases/latest") else {
        state = .failed; return
      }
      var req = URLRequest(url: url)
      req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      do {
        let (data, _) = try await URLSession.shared.data(for: req)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tag = (obj?["tag_name"] as? String) ?? ""
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !latest.isEmpty else { state = .failed; return }
        state = Self.isNewer(latest, than: current) ? .available(latest) : .upToDate
      } catch {
        state = .failed
      }
    }
  }

  /// 更新を適用(updater を launchd で kickstart)。以降 updater が本アプリを差し替え→再起動。
  func apply() {
    state = .updating
    let uid = getuid()
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/net.gapul.keystats.update.plist").path
    if !agentLoaded("net.gapul.keystats.update") { launchctl(["bootstrap", "gui/\(uid)", plist]) }
    launchctl(["kickstart", "-k", "gui/\(uid)/net.gapul.keystats.update"])
  }

  /// semver 風の数値比較($a > $b か)。
  static func isNewer(_ a: String, than b: String) -> Bool {
    func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
      let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
      if l != r { return l > r }
    }
    return false
  }

  @discardableResult
  private func launchctl(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
  }
  private func agentLoaded(_ label: String) -> Bool { launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 }
}

// MARK: - ダッシュボード

struct DashboardView: View {
  @StateObject var model = Model()
  @StateObject private var updater = Updater()
  @ObservedObject var settings = AppSettings.shared   // 言語切替を監視して再描画
  @State private var live = true
  @State private var showUpdateConfirm = false
  private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        // 期間フィルタ(分析カードに反映)
        Picker("", selection: $model.period) {
          ForEach(Period.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
        // 統計カード(総数・今日は常に全期間基準)
        HStack(spacing: 12) {
          StatCard(label: L10n.t("stat.total"), value: model.total.formatted(), accent: true)
          StatCard(label: L10n.t("stat.today"), value: model.today.formatted(),
                   sub: model.total > 0 ? L10n.t("sub.ofTotal", pct(model.today, model.total)) : nil)
          StatCard(label: L10n.t("stat.peakHour"), value: L10n.t("hour.fmt", model.peakHour),
                   sub: L10n.t("sub.hourKeys", model.hourly[model.peakHour].formatted()))
          StatCard(label: L10n.t("stat.topApp"), value: model.topAppName,
                   sub: L10n.t("sub.distinctKeys", model.distinctKeys))
        }
        // 入力速度・精度(期間フィルタに追従)。速度は Delete を除外して算出。
        HStack(spacing: 12) {
          StatCard(label: L10n.t("stat.avgSpeed"), value: "\(model.typing.avgKpm)", sub: L10n.t("sub.kpmFlow"), accent: true)
          StatCard(label: L10n.t("stat.peakSpeed"), value: "\(model.typing.peakKpm)", sub: L10n.t("sub.kpmPeak"))
          StatCard(label: L10n.t("stat.activeTyping"), value: fmtDuration(model.typing.activeSeconds), sub: L10n.t("sub.activeReal"))
          StatCard(label: L10n.t("stat.correction"), value: String(format: "%.1f%%", model.correctionRate),
                   sub: L10n.t("sub.deletes", model.deletes.formatted()))
        }
        Card(title: L10n.t("card.heatmap"), icon: "keyboard") {
          Keyboard(perKey: model.perKey, maxKey: model.maxKey)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.hourly"), icon: "clock") { HourlyChart(hourly: model.hourly, peak: model.peakHour) }
          Card(title: L10n.t("card.daily"), icon: "chart.bar") { DailyTrend(daily: model.daily) }
        }
        Card(title: L10n.t("card.weekday"), icon: "calendar") { WeekdayHeatmap(grid: model.weekday) }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.topKeys"), icon: "trophy") {
            BarList(rows: model.topKeys.map { (label($0.0), $0.1) }, color: Theme.accent, labelWidth: 64, rounded: true)
          }
          Card(title: L10n.t("card.combos"), icon: "command") {
            BarList(rows: model.combos.map { ($0.combo, $0.n) }, color: Theme.accent2, labelWidth: 92, rounded: true)
          }
        }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.appKeys"), icon: "app.badge") {
            BarList(rows: model.apps.prefix(12).map { (shortApp($0.app), $0.n) }, color: Theme.accent, labelWidth: 150)
          }
          Card(title: L10n.t("card.appTime"), icon: "hourglass") {
            BarList(rows: model.appTime.prefix(12).map { (label: shortApp($0.app), n: $0.n) },
                    color: Theme.accent2, labelWidth: 150, valueFmt: fmtDuration)
          }
        }
        Card(title: L10n.t("card.kbType"), icon: "keyboard.badge.ellipsis") {
          BarList(rows: model.kbTypes.map { (kbTypeLabel($0.0), $0.1) }, color: Theme.accent, labelWidth: 150)
        }
      }
      .padding(20)
      .id(settings.lang)          // 言語切替で全再構築 → 全ラベルを即更新
    }
    .background(Theme.bg)
    .frame(minWidth: 900, minHeight: 720)
    .onAppear { model.reload(); updater.check() }
    .onReceive(timer) { _ in if live { model.reload() } }
    .alert(L10n.t("update.available"), isPresented: $showUpdateConfirm) {
      Button(L10n.t("update.now")) { updater.apply() }
      Button(L10n.t("alert.later"), role: .cancel) {}
    } message: {
      if case .available(let v) = updater.state { Text(L10n.t("update.confirmBody", v)) }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "keyboard.fill").foregroundStyle(Theme.accent).font(.system(size: 20))
      VStack(alignment: .leading, spacing: 1) {
        Text("keystats").font(.system(size: 22, weight: .bold))
        Text(L10n.t("app.subtitle")).font(.system(size: 11)).foregroundStyle(Theme.sub)
      }
      Spacer()
      updateControl
      Button {
        live.toggle(); if live { model.reload() }
      } label: {
        HStack(spacing: 5) {
          Circle().fill(live ? Color.green : Theme.sub).frame(width: 7, height: 7)
          Text(live ? L10n.t("live.on") : L10n.t("live.off")).font(.system(size: 12, weight: .medium))
        }
      }.buttonStyle(.bordered)
      Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
        .keyboardShortcut("r")
    }
  }

  // バージョン表示＋更新ボタン。最新なら控えめ、更新ありなら強調ボタン。
  @ViewBuilder private var updateControl: some View {
    switch updater.state {
    case .checking:
      HStack(spacing: 5) {
        ProgressView().controlSize(.small)
        Text(L10n.t("update.checking")).font(.system(size: 12))
      }.foregroundStyle(Theme.sub)
    case .upToDate:
      Button { updater.check() } label: {
        Text("v\(updater.current) · \(L10n.t("update.upToDate"))").font(.system(size: 12))
      }.buttonStyle(.plain).foregroundStyle(Theme.sub)
    case .available(let v):
      Button { showUpdateConfirm = true } label: {
        HStack(spacing: 5) {
          Image(systemName: "arrow.down.circle.fill")
          Text(L10n.t("update.newVer", v)).font(.system(size: 12, weight: .semibold))
        }
      }.buttonStyle(.borderedProminent).tint(Theme.accent)
    case .updating:
      HStack(spacing: 5) {
        ProgressView().controlSize(.small)
        Text(L10n.t("update.updating")).font(.system(size: 12))
      }.foregroundStyle(Theme.accent)
    case .failed:
      Button { updater.check() } label: {
        Text("v\(updater.current) · \(L10n.t("update.failed"))").font(.system(size: 12))
      }.buttonStyle(.plain).foregroundStyle(Theme.sub)
    }
  }

  private func pct(_ a: Int, _ b: Int) -> String {
    b > 0 ? String(format: "%.0f%%", Double(a) / Double(b) * 100) : "0%"
  }
}

// MARK: - AppKit bootstrap (メニューバー常駐 + オンデマンドでウィンドウ)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var statusItem: NSStatusItem!
  var statusTimer: Timer?

  func applicationDidFinishLaunching(_ n: Notification) {
    bootstrapAgents()          // 自分のバンドル位置から LaunchAgent を自己登録
    setupStatusItem()
    setupWindow()
    updateStatus()
    // メニューバーの「今日の打鍵数」はウィンドウの開閉に関係なく更新
    statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateStatus() }          // macOS 13 でも動く形(assumeIsolatedは14+)
    }
    // --background(ログイン起動)ならウィンドウは出さずメニューバーだけ
    if !CommandLine.arguments.contains("--background") { showWindow() }
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let b = statusItem.button {
      // アプリアイコン(キーキャップ)流用のテンプレート画像。無ければSFシンボル。
      let img = NSImage(named: "MenuBarIcon")
        ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "keystats")
      img?.isTemplate = true               // メニューバーの明暗に自動追従
      img?.size = NSSize(width: 18, height: 18)
      b.image = img
      b.imagePosition = .imageLeading
    }
    statusItem.menu = buildMenu()
  }

  // メニューは言語切替で作り直す(項目ラベルを更新するため)。
  private func buildMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: L10n.t("menu.open"), action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(withTitle: L10n.t("menu.checkUpdate"), action: #selector(checkUpdate), keyEquivalent: "")
    let auto = NSMenuItem(title: L10n.t("menu.autoUpdate"), action: #selector(toggleAutoUpdate(_:)), keyEquivalent: "")
    auto.state = autoUpdateEnabled ? .on : .off
    menu.addItem(auto)
    // 言語サブメニュー(自動判定 + 手動切替)
    let langItem = NSMenuItem(title: L10n.t("menu.language"), action: nil, keyEquivalent: "")
    let langMenu = NSMenu()
    for lang in Lang.allCases {
      let it = NSMenuItem(title: lang.displayName, action: #selector(selectLang(_:)), keyEquivalent: "")
      it.representedObject = lang.rawValue
      it.state = (lang == L10n.current) ? .on : .off
      langMenu.addItem(it)
    }
    langItem.submenu = langMenu
    menu.addItem(langItem)
    menu.addItem(.separator())
    menu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    return menu
  }

  @objc func selectLang(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let lang = Lang(rawValue: raw) else { return }
    AppSettings.shared.setLang(lang)   // L10n.current 更新 + GUI 再描画
    statusItem.menu = buildMenu()      // メニュー自身も再構築(ラベル/チェック更新)
  }

  private func setupWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "keystats"
    window.center()
    window.isReleasedWhenClosed = false     // 閉じてもオブジェクトは残す(再表示するため)
    window.contentView = NSHostingView(rootView: DashboardView())
  }

  @objc func showWindow() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  // 手動アップデート確認: keystats-update --check を実行し、更新があれば適用を促す。
  @objc func checkUpdate() {
    let updater = Bundle.main.resourceURL?.appendingPathComponent("keystats-update").path
      ?? "\(NSHomeDirectory())/.local/bin/keystats-update"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [updater, "--check"]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    NSApp.activate(ignoringOtherApps: true)
    do { try p.run() } catch {
      alert(L10n.t("update.checkFail"), "\(error.localizedDescription)"); return
    }
    p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if p.terminationStatus == 10 {         // 更新あり
      let a = NSAlert()
      a.messageText = L10n.t("update.available")
      a.informativeText = out.isEmpty ? L10n.t("update.availableBody") : out
      a.addButton(withTitle: L10n.t("update.now")); a.addButton(withTitle: L10n.t("alert.later"))
      if a.runModal() == .alertFirstButtonReturn {
        // launchd 経由で更新(GUIが再起動されても完走する)。無効化中でも一時的にロードして実行。
        let uid = getuid()
        if !agentLoaded("net.gapul.keystats.update") {
          let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/net.gapul.keystats.update.plist")
          launchctl(["bootstrap", "gui/\(uid)", url.path])
        }
        launchctl(["kickstart", "-k", "gui/\(uid)/net.gapul.keystats.update"])
        alert(L10n.t("update.updatingTitle"), L10n.t("update.updatingBody"))
      }
    } else {
      alert("keystats", out.isEmpty ? L10n.t("update.latest") : out)
    }
  }

  private func alert(_ title: String, _ body: String) {
    let a = NSAlert(); a.messageText = title; a.informativeText = body
    a.addButton(withTitle: L10n.t("alert.ok")); a.runModal()
  }

  // MARK: 設定(UserDefaults)

  var autoUpdateEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "autoUpdate") }
  }

  @objc func toggleAutoUpdate(_ sender: NSMenuItem) {
    autoUpdateEnabled.toggle()
    sender.state = autoUpdateEnabled ? .on : .off
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/net.gapul.keystats.update.plist")
    applyAutoUpdate(autoUpdateEnabled, updateURL: url)
  }

  // MARK: LaunchAgent 自己登録(brew 等でアプリを置くだけでも動く / パスは設置先に自動追従)

  @discardableResult
  private func launchctl(_ args: [String]) -> Int32 {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
  }
  private func agentLoaded(_ label: String) -> Bool { launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 }

  private func applyAutoUpdate(_ enabled: Bool, updateURL: URL) {
    let uid = getuid()
    if enabled {
      if !agentLoaded("net.gapul.keystats.update") { launchctl(["bootstrap", "gui/\(uid)", updateURL.path]) }
    } else {
      launchctl(["bootout", "gui/\(uid)/net.gapul.keystats.update"])
    }
  }

  private func bootstrapAgents() {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let laDir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    try? fm.createDirectory(at: laDir, withIntermediateDirectories: true)
    let app = Bundle.main.bundlePath
    let env = ProcessInfo.processInfo.environment
    func nz(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
    let dataHome  = nz(env["XDG_DATA_HOME"])  ?? home.appendingPathComponent(".local/share").path
    let stateHome = nz(env["XDG_STATE_HOME"]) ?? home.appendingPathComponent(".local/state").path
    try? fm.createDirectory(atPath: "\(dataHome)/keystats", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: "\(stateHome)/keystats", withIntermediateDirectories: true)
    let uid = getuid()

    func esc(_ s: String) -> String {
      s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }
    let xdg = "<key>EnvironmentVariables</key><dict>"
      + "<key>XDG_DATA_HOME</key><string>\(esc(dataHome))</string>"
      + "<key>XDG_STATE_HOME</key><string>\(esc(stateHome))</string></dict>"
    @discardableResult
    func write(_ label: String, _ inner: String) -> URL {
      let url = laDir.appendingPathComponent("\(label).plist")
      let s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        + "<plist version=\"1.0\"><dict><key>Label</key><string>\(label)</string>\(inner)</dict></plist>\n"
      try? s.write(to: url, atomically: true, encoding: .utf8)
      return url
    }

    let dLog = "\(stateHome)/keystats/keystats.log"
    let dURL = write("net.gapul.keystats",
      "<key>ProgramArguments</key><array><string>\(esc(app))/Contents/MacOS/keystatsd</string><string>run</string></array>"
      + "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ProcessType</key><string>Background</string>"
      + xdg
      + "<key>StandardOutPath</key><string>\(esc(dLog))</string><key>StandardErrorPath</key><string>\(esc(dLog))</string>")
    write("net.gapul.keystats.gui",   // ログイン自動起動用。走っている自分は触らない
      "<key>ProgramArguments</key><array><string>\(esc(app))/Contents/MacOS/KeystatsGUI</string><string>--background</string></array>"
      // KeepAlive: 異常終了(クラッシュ)時のみ再起動。ユーザーがメニューから終了(正常終了)したら再起動しない。
      + "<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>"
      + "<key>LimitLoadToSessionType</key><string>Aqua</string>"
      + xdg)
    let uLog = "\(stateHome)/keystats/update.log"
    let uURL = write("net.gapul.keystats.update",
      "<key>ProgramArguments</key><array><string>\(esc(app))/Contents/Resources/keystats-update</string></array>"
      + "<key>RunAtLoad</key><true/><key>StartInterval</key><integer>86400</integer>"
      + "<key>StandardOutPath</key><string>\(esc(uLog))</string><key>StandardErrorPath</key><string>\(esc(uLog))</string>")

    // 記録デーモンは未ロードなら起動(記録を止めないよう、既にロード済みなら触らない)
    if !agentLoaded("net.gapul.keystats") { launchctl(["bootstrap", "gui/\(uid)", dURL.path]) }
    // 自動アップデートは設定に従う
    applyAutoUpdate(autoUpdateEnabled, updateURL: uURL)

    // 初回のみ入力監視パネルを開いて許可を促す
    if !UserDefaults.standard.bool(forKey: "onboarded") {
      UserDefaults.standard.set(true, forKey: "onboarded")
      if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
        NSWorkspace.shared.open(u)
      }
    }
  }

  private let statusStore = Store()   // メニューバー用に接続を使い回す(fdリーク防止)
  func updateStatus() {
    // JST の今日の 0 時以降を集計
    let startHour = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) / 3600
    statusItem.button?.title = " \(statusStore.total(sinceHour: startHour))"
  }

  // ウィンドウを閉じてもアプリは終了させない(メニューバーに残す)
  func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
  // Dock/再オープン時はウィンドウを出す
  func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
    showWindow(); return true
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // Dockアイコンなし = メニューバー常駐
let delegate = AppDelegate()
app.delegate = delegate
app.run()
