import CompilerPluginSupport
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-wire",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Wire", targets: ["Wire"])
    ],
    dependencies: [
        // Pin from M0/Spike 4. Resolves to swift-syntax 601.0.1 on Swift 6.3.x.
        // Bumps to 602.x are deliberate per-Swift-release maintenance events.
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "601.0.0")
    ],
    targets: [
        .target(
            name: "Wire",
            dependencies: ["WireMacrosImpl"]
        ),
        .macro(
            name: "WireMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "WireGen",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "WireMacrosImplTests",
            dependencies: [
                "WireMacrosImpl",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
