import CompilerPluginSupport
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-wire",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "Wire", targets: ["Wire"]),
        .plugin(name: "WireBuildPlugin", targets: ["WireBuildPlugin"]),
    ],
    dependencies: [
        // Range covers 601.0.0 (M0/Spike 4 baseline) through the next-major
        // boundary at 604.0.0. swift-syntax major versions track Swift
        // toolchain releases; per-major bumps are deliberate maintenance
        // events and the upper bound caps that. The widened range avoids
        // forcing downstream consumers off newer validated versions.
        .package(url: "https://github.com/swiftlang/swift-syntax", "601.0.0"..<"604.0.0")
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
        .target(
            name: "WireGenCore",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(
            name: "WireGen",
            dependencies: ["WireGenCore"]
        ),
        .plugin(
            name: "WireBuildPlugin",
            capability: .buildTool(),
            dependencies: ["WireGen"]
        ),
        .testTarget(
            name: "WireMacrosImplTests",
            dependencies: [
                "WireMacrosImpl",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "WireGenCoreTests",
            dependencies: ["WireGenCore"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Wire"],
            plugins: [.plugin(name: "WireBuildPlugin")]
        ),
    ]
)
