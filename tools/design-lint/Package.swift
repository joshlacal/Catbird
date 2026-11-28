// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "design-lint",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "design-lint", targets: ["design-lint"]),
        .library(name: "DesignLintCore", targets: ["DesignLintCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "DesignLintCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "design-lint",
            dependencies: ["DesignLintCore"]
        ),
        .testTarget(
            name: "DesignLintCoreTests",
            dependencies: ["DesignLintCore"]
        ),
    ]
)
