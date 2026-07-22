import AppKit
import SwiftUI
import Combine
import Carbon                 // KBGetLayoutType(実キーボードの ANSI/ISO/JIS 判定)
import KeystatsCore

// keystats-gui — SQLite を読んで打鍵ヒートマップ＋アプリ別打鍵数を表示する SwiftUI ウィンドウ。
// 読み取り専用。入力監視権限は不要(デーモン側だけが要る)。

// MARK: - キーボードレイアウト (ANSI ざっくり)

struct KeyDef { let kc: Int; let w: Double }  // w = 幅ユニット(1 = 標準キー)

let ansiLayout: [[KeyDef]] = [
  [53,122,120,99,118,96,97,98,100,101,109,103,111].map { KeyDef(kc: $0, w: 1) },
  [50,18,19,20,21,23,22,26,28,25,29,27,24].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 51, w: 1.6)],
  [KeyDef(kc: 48, w: 1.6)] + [12,13,14,15,17,16,32,34,31,35,33,30,42].map { KeyDef(kc: $0, w: 1) },
  [KeyDef(kc: 57, w: 1.8)] + [0,1,2,3,5,4,38,40,37,41,39].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 36, w: 1.8)],
  [KeyDef(kc: 56, w: 2.3)] + [6,7,8,9,11,45,46,43,47,44].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 60, w: 2.3)],
  [KeyDef(kc: 63, w: 1), KeyDef(kc: 59, w: 1), KeyDef(kc: 58, w: 1), KeyDef(kc: 55, w: 1.3),
   KeyDef(kc: 49, w: 5.6), KeyDef(kc: 54, w: 1.3), KeyDef(kc: 61, w: 1),
   KeyDef(kc: 123, w: 1), KeyDef(kc: 125, w: 1), KeyDef(kc: 126, w: 1), KeyDef(kc: 124, w: 1)],
]

// JIS(日本語配列)。¥(93)を数字段に追加、英数(102)/かな(104)で短いスペースを挟む、_(94)を右Shift手前。
// キーコードは物理位置で ANSI と共通(刻印だけ違う)。刻印は label(_:jis:) が JIS 用に差し替える。
let jisLayout: [[KeyDef]] = [
  [53,122,120,99,118,96,97,98,100,101,109,103,111].map { KeyDef(kc: $0, w: 1) },
  // 数字段: 1..0 - ^ ¥  (¥=93)
  [18,19,20,21,23,22,26,28,25,29,27,24,93].map { KeyDef(kc: $0, w: 1) } + [KeyDef(kc: 51, w: 1.3)],
  // QWERTY段: Q..P @ [   (@=33, [=30) ※ISO型Enter のため段末はここまで
  [KeyDef(kc: 48, w: 1.6)] + [12,13,14,15,17,16,32,34,31,35,33,30].map { KeyDef(kc: $0, w: 1) },
  // ホーム段: A..L ; : ]  (:=39, ]=42 が JIS ではここ)。Enter は ISO型(縦長)なので別途オーバーレイ。
  [KeyDef(kc: 57, w: 1.6)] + [0,1,2,3,5,4,38,40,37,41,39,42].map { KeyDef(kc: $0, w: 1) },
  // 下段: Z..M , . / _  (_=94)
  [KeyDef(kc: 56, w: 2.0)] + [6,7,8,9,11,45,46,43,47,44].map { KeyDef(kc: $0, w: 1) }
    + [KeyDef(kc: 94, w: 1), KeyDef(kc: 60, w: 1.6)],
  // 最下段: fn ⌃ ⌥ ⌘ 英数 [space] かな ⌘ ⌥ ←↓↑→  (英数=102, かな=104)
  [KeyDef(kc: 63, w: 1), KeyDef(kc: 59, w: 1), KeyDef(kc: 58, w: 1), KeyDef(kc: 55, w: 1.2),
   KeyDef(kc: 102, w: 1.3), KeyDef(kc: 49, w: 3.4), KeyDef(kc: 104, w: 1.3), KeyDef(kc: 54, w: 1.2),
   KeyDef(kc: 61, w: 1), KeyDef(kc: 123, w: 1), KeyDef(kc: 125, w: 1), KeyDef(kc: 126, w: 1), KeyDef(kc: 124, w: 1)],
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
  var stretch = false          // true: 行内で最大高さに伸ばす(HStack を .fixedSize で使う前提)
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
    .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // 行内で高さを揃える(HStack は fixedSize)
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
  var onTap: ((Int) -> Void)? = nil     // 行タップ(index を渡す)
  var body: some View {
    let maxN = max(rows.first?.n ?? 1, 1)
    VStack(spacing: 7) {
      if rows.isEmpty {
        Text(L10n.t("empty")).font(.system(size: 12)).foregroundStyle(Theme.sub)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
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
        .contentShape(Rectangle())
        .onTapGesture { onTap?(i) }
      }
    }
  }
}

// MARK: - キーボード

struct KeyCap: View {
  let def: KeyDef
  let n: Int
  let maxKey: Int
  var jis = false
  var tall: CGFloat? = nil          // ISO型 Enter など縦長キー用の高さ上書き
  var onTap: (() -> Void)? = nil
  static let unit: CGFloat = 46
  static let h: CGFloat = 42
  static let gap: CGFloat = 4       // 行/キー間スペース(レイアウト計算にも使う)
  var body: some View {
    let w = Self.unit * def.w
    VStack(spacing: 1) {
      Text(label(def.kc, jis: jis)).font(.system(size: 11, weight: .medium)).lineLimit(1)
      Text(n > 0 ? "\(n)" : "").font(.system(size: 9)).opacity(0.85)
    }
    .frame(width: w, height: tall ?? Self.h)
    .background(heatColor(n, max: maxKey))
    .foregroundStyle(keyFg)
    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
      .strokeBorder(Theme.border.opacity(n > 0 ? 0 : 1), lineWidth: 1))
    .contentShape(Rectangle())
    .onTapGesture { onTap?() }
  }
  private var keyFg: Color {
    // 色付きセルは常に黒文字(明るいヒート色なので黒が読みやすい)。ゼロは控えめグレー。
    n > 0 ? .black : Theme.sub
  }
}

struct Keyboard: View {
  let perKey: [Int: Int]
  let maxKey: Int
  let layout: [[KeyDef]]
  let jis: Bool
  var onTapKey: ((Int) -> Void)? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: KeyCap.gap) {
      ForEach(Array(layout.enumerated()), id: \.offset) { _, row in
        HStack(spacing: KeyCap.gap) {
          ForEach(Array(row.enumerated()), id: \.offset) { _, k in
            KeyCap(def: k, n: perKey[k.kc] ?? 0, maxKey: maxKey, jis: jis, onTap: { onTapKey?(k.kc) })
          }
        }
      }
    }
    // JIS は ISO型 Enter(縦長: QWERTY段〜ホーム段をぶち抜き)を右端にオーバーレイ。
    .overlay(alignment: .topLeading) {
      if jis {
        let U = KeyCap.unit, H = KeyCap.h, G = KeyCap.gap
        KeyCap(def: KeyDef(kc: 36, w: 1.3), n: perKey[36] ?? 0, maxKey: maxKey, jis: true, tall: 2 * H + G,
               onTap: { onTapKey?(36) })
          .offset(x: 13.6 * U + 13 * G, y: 2 * (H + G))   // ホーム段の右端・QWERTY段の高さから
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
  @Published var hasJISKeys = false   // データに JIS 専用キーの打鍵があるか(配列自動判定用)
  @Published var corrections = 0      // 修正打鍵(削除 + ⌘Z + ⌃H)
  @Published var weakKeys: [(kc: Int, rate: Double, weight: Double)] = []   // 苦手キー(修正直前率 降順)

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
    hasJISKeys = s.hasJISKeys()
    // 修正: Backspace/前方削除 + 取り消し(⌘Z)/Emacs風削除(⌃H)
    corrections = (pk[51] ?? 0) + (pk[117] ?? 0) + s.comboCount(Self.correctionCombos, sinceHour: sh)
    // 苦手キー: 修正直前の重み / 総打鍵。文字キーのみ・打鍵30未満はノイズ除外。
    weakKeys = s.mistypeCounts(sinceHour: sh).compactMap { (kc, w) -> (Int, Double, Double)? in
      guard isTypingKey(kc) else { return nil }
      let total = pk[kc] ?? 0
      guard total >= 30 else { return nil }
      return (kc, w / Double(total) * 100, w)
    }.sorted { $0.1 > $1.1 }.prefix(10).map { (kc: $0.0, rate: $0.1, weight: $0.2) }
  }
  static let correctionCombos = ["⌘Z", "⌃H"]

  // 実キーボードのレイアウト種別。true=JIS, false=ANSI/ISO, nil=不明/データなし。
  // KBGetLayoutType は FourCharCode('ANSI'/'ISO '/'JIS ')を返す。
  var keyboardIsJIS: Bool? {
    guard let kbtype = kbTypes.first?.0 else { return nil }
    let lt = KBGetLayoutType(Int16(truncatingIfNeeded: kbtype))
    if lt == 1_245_773_600 { return true }                     // 'JIS '
    if lt == 1_095_652_169 || lt == 1_230_262_048 { return false }  // 'ANSI' / 'ISO '
    return nil
  }

  var peakHour: Int { hourly.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0 }
  var topAppName: String { apps.first.map { shortApp($0.app) } ?? "—" }
  var distinctKeys: Int { perKey.values.filter { $0 > 0 }.count }
  // 修正率 = 修正打鍵(削除 + ⌘Z + ⌃H) / 総打鍵。入力テキストは記録しないので打ち間違いの近似。
  var periodTotal: Int { perKey.values.reduce(0, +) }
  var correctionRate: Double { periodTotal > 0 ? Double(corrections) / Double(periodTotal) * 100 : 0 }
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

// キーボード配列の指定。auto=データ/言語から推定、ansi/jis=手動固定。
enum LayoutPref: String, CaseIterable { case auto, ansi, jis }

// MARK: - ドリルダウン詳細(キー / アプリ / キーボード)

enum DetailTarget: Identifiable, Hashable {
  case key(Int), app(String), keyboard(Int)
  var id: String {
    switch self {
    case .key(let k): return "k\(k)"; case .app(let a): return "a\(a)"; case .keyboard(let t): return "b\(t)"
    }
  }
}

// ナビゲーション(潜る)のルート。詳細ドリルダウン + 設定ページ。
enum Route: Hashable { case detail(DetailTarget), settings }

// 組み合わせラベルから修飾記号を除いたキー部分("⌘⇧C" → "C")。
func comboKeyPart(_ combo: String) -> String {
  let mods: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
  return String(combo.drop(while: { mods.contains($0) }))
}

@MainActor
final class DetailModel: ObservableObject {
  let target: DetailTarget
  @Published var period: Period { didSet { load() } }
  @Published var total = 0
  @Published var grandTotal = 0
  @Published var perKey: [Int: Int] = [:]
  @Published var maxKey = 0
  @Published var topKeys: [(Int, Int)] = []
  @Published var apps: [AppCount] = []
  @Published var combos: [ComboCount] = []
  @Published var hourly = Array(repeating: 0, count: 24)
  @Published var weekday = Array(repeating: Array(repeating: 0, count: 24), count: 7)
  @Published var daily: [DayCount] = []
  @Published var speed = TypingSummary(activeMs: 0, keys: 0, peakKpm: 0)   // アプリ別の入力速度
  private let s = Store()

  init(target: DetailTarget, period: Period) {
    self.target = target; self.period = period; load()
  }

  private var filter: (kc: Int?, app: String?, kbt: Int?) {
    switch target {
    case .key(let k): return (k, nil, nil)
    case .app(let a): return (nil, a, nil)
    case .keyboard(let t): return (nil, nil, t)
    }
  }

  func load() {
    let off = TimeZone.current.secondsFromGMT() / 3600
    let sh = period.sinceHour
    let f = filter
    grandTotal = s.total()
    total = s.totalCounts(sinceHour: sh, keycode: f.kc, app: f.app, kbtype: f.kbt)
    perKey = s.keyCounts(sinceHour: sh, app: f.app, kbtype: f.kbt)
    maxKey = perKey.values.max() ?? 0
    topKeys = perKey.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
    apps = s.appCounts(sinceHour: sh, keycode: f.kc, kbtype: f.kbt)
    if case .key(let k) = target {
      let key = label(k)                              // combos は ANSI ラベルで保存
      combos = s.allCombos(sinceHour: sh).filter { comboKeyPart($0.combo) == key }
    } else if case .app(let a) = target {
      combos = s.allCombos(sinceHour: sh, app: a)
    } else {
      combos = []                                     // combos に kbtype 次元は無いのでキーボード別は非表示
    }
    hourly = s.hourlyCounts(offsetHours: off, sinceHour: sh, keycode: f.kc, app: f.app, kbtype: f.kbt)
    weekday = s.weekdayCounts(offsetHours: off, sinceHour: sh, keycode: f.kc, app: f.app, kbtype: f.kbt)
    daily = s.dailyCounts(days: 14, offsetHours: off, keycode: f.kc, app: f.app, kbtype: f.kbt)
    if case .app(let a) = target { speed = s.typingSummary(sinceHour: sh, app: a) }   // アプリ別速度
  }

  var peakHour: Int { hourly.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0 }
  var pctOfAll: String { grandTotal > 0 ? String(format: "%.1f%%", Double(total) / Double(grandTotal) * 100) : "0%" }
}

struct DetailView: View {
  @StateObject private var model: DetailModel
  @ObservedObject private var settings = AppSettings.shared
  @Environment(\.dismiss) private var dismiss
  let useJIS: Bool
  let onDrill: (DetailTarget) -> Void      // さらに潜る(キー/アプリ)

  init(target: DetailTarget, period: Period, useJIS: Bool, onDrill: @escaping (DetailTarget) -> Void) {
    _model = StateObject(wrappedValue: DetailModel(target: target, period: period))
    self.useJIS = useJIS
    self.onDrill = onDrill
  }

  private var titleText: String {
    switch model.target {
    case .key(let k): return label(k, jis: useJIS)
    case .app(let a): return shortApp(a)
    case .keyboard(let t): return kbTypeLabel(t)
    }
  }
  private var titleIcon: String {
    switch model.target {
    case .key: return "keyboard"; case .app: return "app.badge"; case .keyboard: return "keyboard.badge.ellipsis"
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        Picker("", selection: $model.period) {
          ForEach(Period.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
        HStack(spacing: 12) {
          StatCard(label: L10n.t("stat.total"), value: model.total.formatted(), accent: true)
          StatCard(label: L10n.t("detail.ofAll"), value: model.pctOfAll)
          StatCard(label: L10n.t("stat.peakHour"), value: L10n.t("hour.fmt", model.peakHour),
                   sub: L10n.t("sub.hourKeys", model.hourly[model.peakHour].formatted()))
        }
        .fixedSize(horizontal: false, vertical: true)
        content
      }
      .padding(20)
      .id(settings.lang)
    }
    .frame(minWidth: 760, minHeight: 680)
    .background(Theme.bg)
    .navigationBarBackButtonHidden(true)     // 自前の戻るを使う
  }

  private var header: some View {
    HStack(spacing: 10) {
      Button { dismiss() } label: {
        HStack(spacing: 3) { Image(systemName: "chevron.left"); Text(L10n.t("back")) }
          .font(.system(size: 13, weight: .medium))
      }.buttonStyle(.plain).foregroundStyle(Theme.accent)
      Divider().frame(height: 16)
      Image(systemName: titleIcon).foregroundStyle(Theme.accent).font(.system(size: 18))
      Text(titleText).font(.system(size: 20, weight: .bold)).lineLimit(1)
      if case .keyboard = model.target {
        Text(L10n.t("detail.sinceAdded")).font(.system(size: 10)).foregroundStyle(Theme.sub)
      }
      Spacer()
    }
  }

  @ViewBuilder private var content: some View {
    switch model.target {
    case .key:
      Card(title: L10n.t("card.appKeys"), icon: "app.badge") {
        BarList(rows: model.apps.prefix(12).map { (shortApp($0.app), $0.n) }, color: Theme.accent, labelWidth: 150,
                onTap: { onDrill(.app(model.apps[$0].app)) })
      }
      Card(title: L10n.t("detail.withMods"), icon: "command") {
        BarList(rows: model.combos.prefix(12).map { ($0.combo, $0.n) }, color: Theme.accent2, labelWidth: 92, rounded: true)
      }
      chartsCards
    case .app, .keyboard:
      if case .app = model.target {
        HStack(spacing: 12) {
          StatCard(label: L10n.t("stat.avgSpeed"), value: "\(model.speed.avgKpm)", sub: L10n.t("sub.kpmFlow"), accent: true)
          StatCard(label: L10n.t("stat.peakSpeed"), value: "\(model.speed.peakKpm)", sub: L10n.t("sub.kpmPeak"))
          StatCard(label: L10n.t("stat.activeTyping"), value: fmtDuration(model.speed.activeSeconds), sub: L10n.t("sub.activeReal"))
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      Card(title: L10n.t("card.heatmap"), icon: "keyboard") {
        Keyboard(perKey: model.perKey, maxKey: model.maxKey, layout: useJIS ? jisLayout : ansiLayout, jis: useJIS,
                 onTapKey: { onDrill(.key($0)) })
          .frame(maxWidth: .infinity, alignment: .center)
      }
      HStack(alignment: .top, spacing: 16) {
        Card(title: L10n.t("card.topKeys"), icon: "trophy", stretch: true) {
          BarList(rows: model.topKeys.map { (label($0.0, jis: useJIS), $0.1) }, color: Theme.accent, labelWidth: 64, rounded: true,
                  onTap: { onDrill(.key(model.topKeys[$0].0)) })
        }
        if case .app = model.target {
          Card(title: L10n.t("card.combos"), icon: "command", stretch: true) {
            BarList(rows: model.combos.prefix(12).map { ($0.combo, $0.n) }, color: Theme.accent2, labelWidth: 92, rounded: true)
          }
        } else {
          Card(title: L10n.t("card.appKeys"), icon: "app.badge", stretch: true) {
            BarList(rows: model.apps.prefix(12).map { (shortApp($0.app), $0.n) }, color: Theme.accent, labelWidth: 150,
                    onTap: { onDrill(.app(model.apps[$0].app)) })
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      chartsCards
    }
  }

  private var chartsCards: some View {
    Group {
      HStack(alignment: .top, spacing: 16) {
        Card(title: L10n.t("card.hourly"), icon: "clock", stretch: true) { HourlyChart(hourly: model.hourly, peak: model.peakHour) }
        Card(title: L10n.t("card.daily"), icon: "chart.bar", stretch: true) { DailyTrend(daily: model.daily) }
      }
      .fixedSize(horizontal: false, vertical: true)
      Card(title: L10n.t("card.weekday"), icon: "calendar") { WeekdayHeatmap(grid: model.weekday) }
    }
  }
}

// 言語などのアプリ全体設定。切替で SwiftUI を再描画するため ObservableObject。
// 外観の設定値。system = macOS のライト/ダークに追従。
enum AppearancePref: String, CaseIterable { case system, light, dark }

@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()
  @Published var lang: Lang = L10n.current          // 解決後の言語(useJIS 等が参照)
  @Published var langPref: LangPref = L10n.pref      // 設定値(system/ja/en, picker 用)
  @Published var layoutPref: LayoutPref =
    UserDefaults.standard.string(forKey: "kbLayout").flatMap(LayoutPref.init) ?? .auto
  @Published var appearance: AppearancePref =
    UserDefaults.standard.string(forKey: "appearance").flatMap(AppearancePref.init) ?? .system
  @Published var pendingSettings = false   // メニュー「設定を開く」→ ダッシュボードが設定ページへ潜る

  func setLangPref(_ p: LangPref) { L10n.apply(p); langPref = p; lang = L10n.current }
  func setLayout(_ p: LayoutPref) { layoutPref = p; UserDefaults.standard.set(p.rawValue, forKey: "kbLayout") }
  func setAppearance(_ p: AppearancePref) {
    appearance = p
    UserDefaults.standard.set(p.rawValue, forKey: "appearance")
    Self.applyAppearance(p)
  }
  // NSApp.appearance を差し替え(nil=システム追従)。Color.dyn がこれに追従する。
  static func applyAppearance(_ p: AppearancePref) {
    NSApp.appearance = p == .system ? nil : NSAppearance(named: p == .dark ? .darkAqua : .aqua)
  }
}

// MARK: - 設定ページ(言語 / キーボード配列 / 自動アップデート)

struct SettingsView: View {
  @ObservedObject private var settings = AppSettings.shared
  @Environment(\.dismiss) private var dismiss
  @State private var autoUpdate = AppDelegate.shared?.autoUpdateEnabled ?? true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          Button { dismiss() } label: {
            HStack(spacing: 3) { Image(systemName: "chevron.left"); Text(L10n.t("back")) }
              .font(.system(size: 13, weight: .medium))
          }.buttonStyle(.plain).foregroundStyle(Theme.accent)
          Divider().frame(height: 16)
          Image(systemName: "gearshape.fill").foregroundStyle(Theme.accent).font(.system(size: 18))
          Text(L10n.t("settings.title")).font(.system(size: 20, weight: .bold))
          Spacer()
        }
        Card(title: L10n.t("settings.appearance"), icon: "circle.lefthalf.filled") {
          Picker("", selection: Binding(get: { settings.appearance }, set: { settings.setAppearance($0) })) {
            Text(L10n.t("appearance.system")).tag(AppearancePref.system)
            Text(L10n.t("appearance.light")).tag(AppearancePref.light)
            Text(L10n.t("appearance.dark")).tag(AppearancePref.dark)
          }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
        }
        Card(title: L10n.t("menu.language"), icon: "globe") {
          Picker("", selection: Binding(get: { settings.langPref }, set: { settings.setLangPref($0) })) {
            Text(L10n.t("lang.system")).tag(LangPref.system)
            Text("日本語").tag(LangPref.ja)
            Text("English").tag(LangPref.en)
          }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
        }
        Card(title: L10n.t("menu.layout"), icon: "keyboard") {
          Picker("", selection: Binding(get: { settings.layoutPref }, set: { settings.setLayout($0) })) {
            ForEach(LayoutPref.allCases, id: \.self) { Text(L10n.t("layout.\($0.rawValue)")).tag($0) }
          }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
          Text(L10n.t("settings.layoutHint")).font(.system(size: 11)).foregroundStyle(Theme.sub)
        }
        Card(title: L10n.t("menu.autoUpdate"), icon: "arrow.triangle.2.circlepath") {
          Toggle(isOn: Binding(get: { autoUpdate }, set: { autoUpdate = $0; AppDelegate.shared?.setAutoUpdate($0) })) {
            Text(L10n.t("settings.autoUpdateHint")).font(.system(size: 12)).foregroundStyle(Theme.sub)
          }
        }
        Card(title: L10n.t("uninstall.title"), icon: "trash") {
          Text(L10n.t("uninstall.body")).font(.system(size: 12)).foregroundStyle(Theme.sub)
          Button(L10n.t("uninstall.button")) { AppDelegate.shared?.confirmUninstall() }
            .buttonStyle(.bordered).tint(.red)
        }
      }.padding(20)
    }
    .frame(minWidth: 520, minHeight: 460)
    .background(Theme.bg)
    .navigationBarBackButtonHidden(true)
  }
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
  @State private var path: [Route] = []   // 潜るナビゲーション(詳細ドリルダウン + 設定)
  private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

  var body: some View {
    NavigationStack(path: $path) {
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
        .fixedSize(horizontal: false, vertical: true)   // 4枚を同じ高さに揃える
        // 入力速度・精度(期間フィルタに追従)。速度は Delete を除外して算出。
        HStack(spacing: 12) {
          StatCard(label: L10n.t("stat.avgSpeed"), value: "\(model.typing.avgKpm)", sub: L10n.t("sub.kpmFlow"), accent: true)
          StatCard(label: L10n.t("stat.peakSpeed"), value: "\(model.typing.peakKpm)", sub: L10n.t("sub.kpmPeak"))
          StatCard(label: L10n.t("stat.activeTyping"), value: fmtDuration(model.typing.activeSeconds), sub: L10n.t("sub.activeReal"))
          StatCard(label: L10n.t("stat.correction"), value: String(format: "%.1f%%", model.correctionRate),
                   sub: L10n.t("sub.corrections", model.corrections.formatted()))
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: L10n.t("card.heatmap"), icon: "keyboard") {
          Keyboard(perKey: model.perKey, maxKey: model.maxKey,
                   layout: useJIS ? jisLayout : ansiLayout, jis: useJIS,
                   onTapKey: { path.append(.detail(.key($0))) })
            .frame(maxWidth: .infinity, alignment: .center)
        }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.hourly"), icon: "clock", stretch: true) { HourlyChart(hourly: model.hourly, peak: model.peakHour) }
          Card(title: L10n.t("card.daily"), icon: "chart.bar", stretch: true) { DailyTrend(daily: model.daily) }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: L10n.t("card.weekday"), icon: "calendar") { WeekdayHeatmap(grid: model.weekday) }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.topKeys"), icon: "trophy", stretch: true) {
            BarList(rows: model.topKeys.map { (label($0.0, jis: useJIS), $0.1) }, color: Theme.accent, labelWidth: 64, rounded: true,
                    onTap: { path.append(.detail(.key(model.topKeys[$0].0))) })
          }
          Card(title: L10n.t("card.weakKeys"), icon: "exclamationmark.triangle", stretch: true) {
            BarList(rows: model.weakKeys.map { (label($0.kc, jis: useJIS), Int(($0.rate * 100).rounded())) },
                    color: Theme.accent2, labelWidth: 64, rounded: true,
                    valueFmt: { String(format: "%.2f%%", Double($0) / 100) },
                    onTap: { path.append(.detail(.key(model.weakKeys[$0].kc))) })
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: L10n.t("card.combos"), icon: "command") {
          BarList(rows: model.combos.map { ($0.combo, $0.n) }, color: Theme.accent2, labelWidth: 92, rounded: true)
        }
        HStack(alignment: .top, spacing: 16) {
          Card(title: L10n.t("card.appKeys"), icon: "app.badge", stretch: true) {
            BarList(rows: model.apps.prefix(12).map { (shortApp($0.app), $0.n) }, color: Theme.accent, labelWidth: 150,
                    onTap: { path.append(.detail(.app(model.apps[$0].app))) })
          }
          Card(title: L10n.t("card.appTime"), icon: "hourglass", stretch: true) {
            BarList(rows: model.appTime.prefix(12).map { (label: shortApp($0.app), n: $0.n) },
                    color: Theme.accent2, labelWidth: 150, valueFmt: fmtDuration,
                    onTap: { path.append(.detail(.app(model.appTime[$0].app))) })
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: L10n.t("card.kbType"), icon: "keyboard.badge.ellipsis") {
          BarList(rows: model.kbTypes.map { (kbTypeLabel($0.0), $0.1) }, color: Theme.accent, labelWidth: 150,
                  onTap: { path.append(.detail(.keyboard(model.kbTypes[$0].0))) })
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
    .navigationDestination(for: Route.self) { route in
      switch route {
      case .detail(let t):
        DetailView(target: t, period: model.period, useJIS: useJIS, onDrill: { path.append(.detail($0)) })
      case .settings:
        SettingsView()
      }
    }
    .onChange(of: settings.pendingSettings) { v in
      if v { path.append(.settings); settings.pendingSettings = false }   // メニューから設定へ
    }
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
      Button { path.append(.settings) } label: { Image(systemName: "gearshape") }
        .keyboardShortcut(",")
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

  // 使用する配列。auto の判定は正確な順: JIS専用キーの記録 → 実キーボード種別 → (不明時のみ)言語。
  // 地域(JP)は使わない: 日本在住でも US 配列の人がいるため誤爆する。
  private var useJIS: Bool {
    switch settings.layoutPref {
    case .ansi: return false
    case .jis:  return true
    case .auto:
      if model.hasJISKeys { return true }              // 英数/かな/¥ の記録あり → JIS確定
      if let jis = model.keyboardIsJIS { return jis }  // 実キーボードの種別で確定
      return settings.lang == .ja                       // 不明時のみ言語で推定
    }
  }
}

// MARK: - AppKit bootstrap (メニューバー常駐 + オンデマンドでウィンドウ)

struct InstallLocationView: View {
  let install: () -> Void
  @State private var moving = false

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "arrow.down.app.fill")
        .font(.system(size: 54, weight: .medium)).foregroundStyle(Theme.accent)
      VStack(spacing: 8) {
        Text(L10n.t("install.title")).font(.system(size: 28, weight: .bold))
        Text(L10n.t("install.lead")).font(.system(size: 15)).foregroundStyle(Theme.sub)
          .multilineTextAlignment(.center)
      }
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "folder.fill").font(.system(size: 21)).foregroundStyle(Theme.accent)
        Text(L10n.t("install.body")).font(.system(size: 13)).foregroundStyle(Theme.sub)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(18).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14))
      Button {
        moving = true; install()
      } label: {
        HStack(spacing: 8) {
          if moving { ProgressView().controlSize(.small) }
          Text(moving ? L10n.t("install.moving") : L10n.t("install.move"))
        }
      }
      .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent).disabled(moving)
    }
    .padding(.horizontal, 48).padding(.top, 40).padding(.bottom, 32)
    .frame(width: 600, height: 420, alignment: .top).background(Theme.bg)
  }
}

struct OnboardingView: View {
  let permissionGranted: () -> Bool
  let openPermissionSettings: () -> Void
  let repairPermission: () -> Void
  let finish: () -> Void
  let previewMode: Bool
  @State private var granted = false
  @State private var showPermissionHelp = false
  private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: granted ? "checkmark.circle.fill" : "keyboard.fill")
        .font(.system(size: 54, weight: .medium))
        .foregroundStyle(granted ? Color.green : Theme.accent)

      VStack(spacing: 8) {
        Text(granted ? L10n.t("onboarding.ready.title") : L10n.t("onboarding.title"))
          .font(.system(size: 28, weight: .bold))
        Text(granted ? L10n.t("onboarding.ready.body") : L10n.t("onboarding.lead"))
          .font(.system(size: 15)).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
      }

      if !granted {
        VStack(spacing: 0) {
          onboardingRow(icon: "hand.raised.fill", title: L10n.t("onboarding.privacy.title"),
                        body: L10n.t("onboarding.privacy.body"), done: true)
          Divider().padding(.leading, 52)
          onboardingRow(icon: "gearshape.fill", title: L10n.t("onboarding.permission.title"),
                        body: L10n.t("onboarding.permission.body"), done: false)
        }
        .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 14))
      }

      Button(granted ? L10n.t("onboarding.start") : L10n.t("onboarding.openSettings")) {
        if granted { finish() }
        else if previewMode { withAnimation { granted = true } }
        else { openPermissionSettings() }
      }
      .buttonStyle(.borderedProminent).controlSize(.large).tint(Theme.accent)

      if !granted {
        VStack(spacing: 12) {
          HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text(L10n.t("onboarding.waiting")).font(.system(size: 12)).foregroundStyle(Theme.sub)
          }
          DisclosureGroup(L10n.t("onboarding.help.title"), isExpanded: $showPermissionHelp) {
            VStack(alignment: .leading, spacing: 10) {
              Text(L10n.t("onboarding.help.body"))
                .font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
              Button(L10n.t("onboarding.help.repair")) { repairPermission() }
                .buttonStyle(.bordered).controlSize(.small)
            }.padding(.top, 8)
          }
          .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.sub)
        }
      }
    }
    .padding(.horizontal, 48).padding(.top, 32).padding(.bottom, 28)
    .frame(width: 600, height: 500, alignment: .top)
    .background(Theme.bg)
    .onAppear { granted = permissionGranted() }
    .onReceive(permissionTimer) { _ in
      if !granted { withAnimation { granted = permissionGranted() } }
    }
  }

  private func onboardingRow(icon: String, title: String, body: String, done: Bool) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: done ? "checkmark.circle.fill" : icon)
        .font(.system(size: 20)).foregroundStyle(done ? Color.green : Theme.accent).frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.system(size: 14, weight: .semibold))
        Text(body).font(.system(size: 12)).foregroundStyle(Theme.sub).fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
    }.padding(16)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var shared: AppDelegate?   // 設定ページから自動アップデート等を呼ぶため
  var window: NSWindow!
  var statusItem: NSStatusItem!
  var statusTimer: Timer?

  func applicationDidFinishLaunching(_ n: Notification) {
    if ProcessInfo.processInfo.environment["KEYSTATS_PREVIEW_INSTALL"] == "1" {
      AppDelegate.shared = self
      AppSettings.applyAppearance(AppSettings.shared.appearance)
      setupInstallLocationPreview()
      showWindow()
      return
    }
    // 開発時の初回画面確認用。実際のLaunchAgent・権限・設定には触れない。
    if ProcessInfo.processInfo.environment["KEYSTATS_PREVIEW_ONBOARDING"] == "1" {
      AppDelegate.shared = self
      AppSettings.applyAppearance(AppSettings.shared.appearance)
      setupOnboardingPreview()
      showWindow()
      return
    }
    // zipから直接開いた場合は、常駐登録より先に安定した場所へ移す。
    if shouldOfferApplicationMove {
      AppDelegate.shared = self
      AppSettings.applyAppearance(AppSettings.shared.appearance)
      setupInstallLocationWindow()
      showWindow()
      return
    }
    // 多重起動ガード。ログイン時に launchd(--background) と macOS の状態復元/旧ログイン項目が
    // 重なっても、2個目は静かに終了して常に1インスタンスに保つ。常駐する --background 版は
    // 決して自分から降りず、フォアグラウンド起動(手動/復元)の重複だけが引き下がる。
    // 通常の再オープンは applicationShouldHandleReopen が既存インスタンスの窓を出すので、
    // このガードで手動起動のUXは損なわれない。
    if !CommandLine.arguments.contains("--background") {
      let mePID = NSRunningApplication.current.processIdentifier
      let bid = Bundle.main.bundleIdentifier ?? "net.gapul.keystats.gui"
      let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != mePID }
      if !others.isEmpty {
        let myPath = Bundle.main.bundleURL.standardizedFileURL.path
        let installed = myPath.hasPrefix("/Applications/")
          || myPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path + "/")
        if installed, others.allSatisfy({ app in
          guard let url = app.bundleURL?.standardizedFileURL else { return false }
          return !url.path.hasPrefix("/Applications/")
            && !url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
              .appendingPathComponent("Applications").path + "/")
        }) {
          // 移動直後の新アプリを優先し、ダウンロード元で動く旧プロセスを終了する。
          others.forEach { $0.terminate() }
        } else {
          others.first?.activate(options: [])   // 通常の重複起動は既存インスタンスを前面へ
          NSApp.terminate(nil)
          return
        }
      }
    }
    AppDelegate.shared = self
    AppSettings.applyAppearance(AppSettings.shared.appearance)   // 保存された外観(ライト/ダーク/システム)を適用
    bootstrapAgents()          // 自分のバンドル位置から LaunchAgent を自己登録
    setupStatusItem()
    setupWindow()
    updateStatus()
    // メニューバーの「今日の打鍵数」はウィンドウの開閉に関係なく更新
    statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.updateStatus() }          // macOS 13 でも動く形(assumeIsolatedは14+)
    }
    // 初回設定が済んでいなければ、ログイン起動でも案内を見失わないよう表示する。
    if needsOnboarding || !CommandLine.arguments.contains("--background") { showWindow() }
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
    let menu = NSMenu()
    menu.delegate = self          // 開くたびに作り直す(言語変更にラベルを追従)
    populateMenu(menu)
    statusItem.menu = menu
  }

  // メニュー項目を(再)構築。言語変更でラベルが変わるため menuNeedsUpdate から呼び直す。
  private func populateMenu(_ menu: NSMenu) {
    menu.removeAllItems()
    menu.addItem(withTitle: L10n.t("menu.open"), action: #selector(showWindow), keyEquivalent: "")
    menu.addItem(withTitle: L10n.t("menu.checkUpdate"), action: #selector(checkUpdate), keyEquivalent: "")
    menu.addItem(withTitle: L10n.t("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
    menu.addItem(.separator())
    menu.addItem(withTitle: L10n.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  }

  // 設定はダッシュボード内の設定ページで行う。メニューからはウィンドウを出して設定へ潜る。
  @objc func openSettings() {
    showWindow()
    AppSettings.shared.pendingSettings = true
  }

  // 自動アップデートの有効/無効(設定ページから呼ばれる)。launchd エージェントを付け外し。
  func setAutoUpdate(_ enabled: Bool) {
    autoUpdateEnabled = enabled
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/net.gapul.keystats.update.plist")
    applyAutoUpdate(enabled, updateURL: url)
  }

  func confirmUninstall() {
    let a = NSAlert()
    a.alertStyle = .warning
    a.messageText = L10n.t("uninstall.confirm")
    a.informativeText = L10n.t("uninstall.confirmBody")
    a.addButton(withTitle: L10n.t("uninstall.action"))
    a.addButton(withTitle: L10n.t("alert.cancel"))
    guard a.runModal() == .alertFirstButtonReturn else { return }

    guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("keystats-uninstall"),
          FileManager.default.fileExists(atPath: bundled.path) else {
      alert("Keystats", L10n.t("uninstall.failed")); return
    }
    let helper = FileManager.default.temporaryDirectory
      .appendingPathComponent("keystats-uninstall-\(UUID().uuidString)")
    do {
      try FileManager.default.copyItem(at: bundled, to: helper)
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash")
      p.arguments = [helper.path, Bundle.main.bundleURL.standardizedFileURL.path]
      try p.run()
      NSApp.terminate(nil)
    } catch {
      try? FileManager.default.removeItem(at: helper)
      alert("Keystats", error.localizedDescription)
    }
  }

  private func setupWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "keystats"
    window.center()
    window.isReleasedWhenClosed = false     // 閉じてもオブジェクトは残す(再表示するため)
    showAppropriateContent()
  }

  private func setupOnboardingPreview() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "Keystats — Onboarding Preview"
    window.center()
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: OnboardingView(
      permissionGranted: { false }, openPermissionSettings: {},
      repairPermission: { [weak self] in
        self?.alert("Preview", "実際の権限やデータは変更せず、修復ボタンの表示だけを確認しています。")
      },
      finish: { NSApp.terminate(nil) }, previewMode: true))
  }

  private var shouldOfferApplicationMove: Bool {
    if ProcessInfo.processInfo.environment["KEYSTATS_SKIP_APP_MOVE"] == "1" { return false }
    let url = Bundle.main.bundleURL.standardizedFileURL
    guard url.pathExtension == "app" else { return false }
    let path = url.path
    let userApplications = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications", isDirectory: true).path + "/"
    return !path.hasPrefix("/Applications/") && !path.hasPrefix(userApplications)
  }

  private func setupInstallLocationWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Keystats"
    window.center(); window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: InstallLocationView(
      install: { [weak self] in self?.moveToApplications() }))
  }

  private func setupInstallLocationPreview() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
      styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    window.title = "Keystats — Install Preview"
    window.center(); window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: InstallLocationView(install: { [weak self] in
      self?.alert("Preview", "実際のアプリやデータは移動していません。")
      self?.setupInstallLocationPreview(); self?.showWindow()
    }))
  }

  private func moveToApplications() {
    let fm = FileManager.default
    let source = Bundle.main.bundleURL.standardizedFileURL
    let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let userApplications = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    let parent = fm.isWritableFile(atPath: systemApplications.path) ? systemApplications : userApplications
    do {
      try fm.createDirectory(at: parent, withIntermediateDirectories: true)
      let destination = parent.appendingPathComponent("Keystats.app", isDirectory: true)
      let candidate = parent.appendingPathComponent(".Keystats.install.\(getpid()).app", isDirectory: true)
      let backup = parent.appendingPathComponent(".Keystats.backup.\(getpid()).app", isDirectory: true)
      try? fm.removeItem(at: candidate); try? fm.removeItem(at: backup)

      let copy = Process(); copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
      copy.arguments = [source.path, candidate.path]
      try copy.run(); copy.waitUntilExit()
      guard copy.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }

      let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
      verify.arguments = ["--verify", "--deep", "--strict", candidate.path]
      verify.standardOutput = FileHandle.nullDevice; verify.standardError = FileHandle.nullDevice
      try verify.run(); verify.waitUntilExit()
      guard verify.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

      // 同じbundle idの旧版を止め、既存アプリは差し替え完了まで退避する。
      let uid = getuid()
      for label in ["net.gapul.keystats", "net.gapul.keystats.gui", "net.gapul.keystats.update"] {
        launchctl(["bootout", "gui/\(uid)/\(label)"])
      }
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: "net.gapul.keystats.gui")
        where app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.terminate() }

      if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: backup) }
      do { try fm.moveItem(at: candidate, to: destination) }
      catch {
        if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: destination) }
        throw error
      }
      try? fm.removeItem(at: backup)

      let config = NSWorkspace.OpenConfiguration(); config.activates = true
      NSWorkspace.shared.openApplication(at: destination, configuration: config) { [weak self] _, error in
        Task { @MainActor in
          if let error { self?.alert(L10n.t("install.failed"), error.localizedDescription) }
          else { NSApp.terminate(nil) }
        }
      }
    } catch {
      alert(L10n.t("install.failed"), error.localizedDescription)
      setupInstallLocationWindow(); showWindow()
    }
  }

  private var needsOnboarding: Bool {
    !UserDefaults.standard.bool(forKey: "onboarded") || !inputMonitoringGranted()
  }

  private func showAppropriateContent() {
    if needsOnboarding {
      window.contentView = NSHostingView(rootView: OnboardingView(
        permissionGranted: { [weak self] in self?.inputMonitoringGranted() ?? false },
        openPermissionSettings: { [weak self] in self?.openInputMonitoringSettings() },
        repairPermission: { [weak self] in self?.repairInputMonitoringPermission() },
        finish: { [weak self] in self?.finishOnboarding() }, previewMode: false))
    } else {
      window.contentView = NSHostingView(rootView: DashboardView())
    }
  }

  private func inputMonitoringGranted() -> Bool {
    let daemon = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keystatsd")
    guard FileManager.default.isExecutableFile(atPath: daemon.path) else { return false }
    let p = Process(); p.executableURL = daemon; p.arguments = ["permission"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
  }

  private func openInputMonitoringSettings() {
    // 未許可で終了しているデーモンを一度起動し、macOSの一覧へ確実に登録する。
    launchctl(["kickstart", "-k", "gui/\(getuid())/net.gapul.keystats"])
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
      NSWorkspace.shared.open(url)
    }
  }

  private func repairInputMonitoringPermission() {
    launchctl(["bootout", "gui/\(getuid())/net.gapul.keystats"])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
    p.arguments = ["reset", "ListenEvent", "net.gapul.keystats"]
    do {
      try p.run(); p.waitUntilExit()
      guard p.terminationStatus == 0 else {
        alert("Keystats", L10n.t("onboarding.help.failed")); return
      }
      // plistは既に自己登録済み。再ロードしてmacOSの入力監視一覧へ登録し直す。
      let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/net.gapul.keystats.plist").path
      launchctl(["bootstrap", "gui/\(getuid())", plist])
      openInputMonitoringSettings()
    } catch {
      alert("Keystats", L10n.t("onboarding.help.failed"))
    }
  }

  private func finishOnboarding() {
    guard inputMonitoringGranted() else { return }
    UserDefaults.standard.set(true, forKey: "onboarded")
    launchctl(["kickstart", "-k", "gui/\(getuid())/net.gapul.keystats"])
    window.contentView = NSHostingView(rootView: DashboardView())
    window.setContentSize(NSSize(width: 820, height: 620))
    window.center()
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

extension AppDelegate: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) { populateMenu(menu) }   // 開くたび現在言語で作り直す
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // Dockアイコンなし = メニューバー常駐
let delegate = AppDelegate()
app.delegate = delegate
app.run()
