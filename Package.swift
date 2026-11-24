// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BatteryBar",
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
            name: "BatteryBar",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryBar",
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
            name: "BatteryBarHelper",
            dependencies: ["TelemetryCore"],
            path: "Sources/BatteryBarHelper"
        ),
        // 单元测试
        .testTarget(
            name: "BatteryBarTests",
            dependencies: ["BatteryBar", "TelemetryCore"],
            path: "Tests/BatteryBarTests"
        ),
    ]
)
