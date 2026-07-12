// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "keystats",
  platforms: [.macOS(.v13)],
  targets: [
    // 共有コア: パス / keycode ラベル / SQLite 読み書き
    .target(
      name: "KeystatsCore",
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    // 記録デーモン + CLI
    .executableTarget(
      name: "keystats",
      dependencies: ["KeystatsCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
    // SwiftUI ダッシュボード
    .executableTarget(
      name: "KeystatsGUI",
      dependencies: ["KeystatsCore"],
      linkerSettings: [.linkedLibrary("sqlite3")]
    ),
  ]
)
