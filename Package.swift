// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BatteryArchive",
    platforms: [.macOS(.v14)],
    targets: [
        // App 与特权 Helper 共用的纯解析/归一化逻辑，保持协议两端口径一致并可单测。
        .target(
            name: "TelemetryCore",
            dependencies: [],
            path: "Sources/TelemetryCore"
        ),
        // 主应用
        .executableTarget(
            name: "BatteryArchive",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryArchive",
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Charts"),
                .linkedFramework("Security"),
                .linkedFramework("ImageIO"),
            ]
        ),
        // 可选按需特权分项采样 Helper
        .executableTarget(
            name: "BatteryArchiveHelper",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryArchiveHelper"
        ),
        // 单元测试
        .testTarget(
            name: "BatteryArchiveTests",
            dependencies: ["BatteryArchive", "TelemetryCore"],
            path: "Tests/BatteryArchiveTests"
        ),
    ]
)
