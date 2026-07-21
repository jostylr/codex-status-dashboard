// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "codex-status-dashboard", targets: ["CodexStatusDashboard"]),
        .executable(name: "codex-status-hook", targets: ["CodexStatusHook"]),
    ],
    targets: [
        .target(name: "StatusProtocol"),
        .target(name: "DashboardSupport"),
        .executableTarget(
            name: "CodexStatusDashboard",
            dependencies: ["StatusProtocol", "DashboardSupport"]
        ),
        .executableTarget(
            name: "CodexStatusHook",
            dependencies: ["StatusProtocol"]
        ),
        .testTarget(
            name: "StatusProtocolTests",
            dependencies: ["StatusProtocol"]
        ),
        .testTarget(
            name: "DashboardSupportTests",
            dependencies: ["DashboardSupport"]
        ),
    ]
)
