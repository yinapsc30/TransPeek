// swift-tools-version: 6.0
import PackageDescription

// TransPeek 的核心逻辑：不依赖 AppKit UI，全部可以用 `swift test` 测试（design.md「模块划分」）。
let package = Package(
    name: "TransPeekKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TransPeekKit", targets: ["TransPeekKit"]),
    ],
    targets: [
        .target(
            name: "TransPeekKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TransPeekKitTests",
            dependencies: ["TransPeekKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
