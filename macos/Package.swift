// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MCPIndicator",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MCPIndicator",
            path: "Sources/MCPIndicator"
        ),
        .testTarget(
            name: "MCPIndicatorTests",
            dependencies: ["MCPIndicator"],
            path: "Tests/MCPIndicatorTests"
        ),
    ]
)
