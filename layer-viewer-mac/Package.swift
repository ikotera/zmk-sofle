// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LayerViewer",
    platforms: [.macOS(.v13)],
    targets: [
        // 画面・OS の機能に依存しないコア（キーマップの解釈・ラベル・Studio RPC・記録の判定）
        .target(name: "LayerViewerCore"),
        // AppKit のアプリ本体（最前面の小窓・メニューバー・HID・記録の書き出し）
        .executableTarget(name: "LayerViewer", dependencies: ["LayerViewerCore"]),
        .testTarget(name: "LayerViewerCoreTests", dependencies: ["LayerViewerCore"]),
    ]
)
