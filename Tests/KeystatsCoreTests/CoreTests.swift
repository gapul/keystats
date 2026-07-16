import XCTest
@testable import KeystatsCore

final class CoreTests: XCTestCase {

  // MARK: ラベル / キー分類

  func testJISLabels() {
    XCTAssertEqual(label(24, jis: false), "=")     // ANSI
    XCTAssertEqual(label(24, jis: true), "^")      // JIS 刻印差
    XCTAssertEqual(label(33, jis: true), "@")
    XCTAssertEqual(label(93, jis: true), "¥")
    XCTAssertEqual(label(102, jis: true), "英数")
    XCTAssertEqual(label(0, jis: true), "A")       // 差の無いキーはそのまま
  }

  func testIsTypingKey() {
    XCTAssertTrue(isTypingKey(0))    // A
    XCTAssertTrue(isTypingKey(29))   // 0
    XCTAssertTrue(isTypingKey(41))   // ;
    XCTAssertFalse(isTypingKey(53))  // Esc
    XCTAssertFalse(isTypingKey(55))  // Cmd
    XCTAssertFalse(isTypingKey(51))  // Delete
    XCTAssertFalse(isTypingKey(123)) // ←
    XCTAssertFalse(isTypingKey(36))  // Return
  }

  // MARK: L10n

  func testL10nFallback() {
    XCTAssertEqual(L10n.t("___no_such_key___"), "___no_such_key___")   // 未定義はキーを返す
    XCTAssertFalse(L10n.t("stat.total").isEmpty)
    XCTAssertEqual(L10n.weekdays.count, 7)
  }

  // MARK: Store 読み書き(一時DB)

  private func makeStore() -> (Store, String) {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("keystats-test-\(UUID().uuidString).db").path
    return (Store(path: path), path)
  }

  func testKeyAndAppCounts() {
    let (s, path) = makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    s.bump(hour: 100, keycode: 0, app: "com.test.a")
    s.bump(hour: 100, keycode: 0, app: "com.test.a")
    s.bump(hour: 100, keycode: 0, app: "com.test.b")
    s.bump(hour: 100, keycode: 1, app: "com.test.a")
    XCTAssertEqual(s.perKey()[0], 3)
    XCTAssertEqual(s.total(), 4)
    // フィルタ: キー0 のアプリ内訳
    let apps = s.appCounts(keycode: 0)
    XCTAssertEqual(apps.first?.app, "com.test.a")
    XCTAssertEqual(apps.first?.n, 2)
    // フィルタ: アプリ a のキー内訳
    XCTAssertEqual(s.keyCounts(app: "com.test.a")[0], 2)
    XCTAssertEqual(s.totalCounts(app: "com.test.a"), 3)
  }

  func testKeyboardDimension() {
    let (s, path) = makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    s.bumpCountKb(hour: 100, keycode: 0, app: "com.test", kbtype: 46)
    s.bumpCountKb(hour: 100, keycode: 0, app: "com.test", kbtype: 46)
    s.bumpCountKb(hour: 100, keycode: 0, app: "com.test", kbtype: 91)
    XCTAssertEqual(s.keyCounts(kbtype: 46)[0], 2)
    XCTAssertEqual(s.keyCounts(kbtype: 91)[0], 1)
    XCTAssertEqual(s.totalCounts(kbtype: 46), 2)
  }

  func testMistypeWeights() {
    let (s, path) = makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    s.bumpMistype(hour: 100, keycode: 0, weight: 1.0)
    s.bumpMistype(hour: 100, keycode: 0, weight: 0.5)   // 等比の別の項が同じキーに乗る想定
    s.bumpMistype(hour: 100, keycode: 1, weight: 0.25)
    let mt = s.mistypeCounts()
    XCTAssertEqual(mt[0]!, 1.5, accuracy: 1e-9)
    XCTAssertEqual(mt[1]!, 0.25, accuracy: 1e-9)
  }

  func testTypingSummaryAndCombo() {
    let (s, path) = makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    s.bumpTyping(hour: 100, activeMs: 60_000, peakKpm: 400)  // 1分間に…
    s.bumpTyping(hour: 100, activeMs: 60_000, peakKpm: 500)  // keys=2, active=120s
    let t = s.typingSummary()
    XCTAssertEqual(t.keys, 2)
    XCTAssertEqual(t.peakKpm, 500)                 // MAX
    XCTAssertEqual(t.avgKpm, 1)                    // 2 keys / 2 min = 1 KPM
    s.bumpCombo(hour: 100, combo: "⌘Z", app: "com.test")
    s.bumpCombo(hour: 100, combo: "⌃H", app: "com.test")
    s.bumpCombo(hour: 100, combo: "⌘C", app: "com.test")
    XCTAssertEqual(s.comboCount(["⌘Z", "⌃H"]), 2)  // 修正コンボのみ
  }

  func testSinceHourFilter() {
    let (s, path) = makeStore()
    defer { try? FileManager.default.removeItem(atPath: path) }
    s.bump(hour: 100, keycode: 0, app: "com.test")
    s.bump(hour: 200, keycode: 0, app: "com.test")
    XCTAssertEqual(s.total(), 2)
    XCTAssertEqual(s.total(sinceHour: 150), 1)
    XCTAssertEqual(s.totalCounts(sinceHour: 150, keycode: 0), 1)
  }
}
