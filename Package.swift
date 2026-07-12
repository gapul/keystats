// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "keystats",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(
      name: "keystats",
      // macOS 標準の sqlite3 をリンク（外部依存なし）
      linkerSettings: [.linkedLibrary("sqlite3")]
    )
  ]
)
