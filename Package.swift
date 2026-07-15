// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "swift-wire",
    platforms: [
        // macOS 15 is required for the `Synchronization` module's
        // `Mutex` type, used by `Wire.AtomicState<T>`. Linux is
        // unaffected (Synchronization ships with Swift 6.0+ on
        // Linux); this constraint only narrows the development-on-
        // macOS audience to macOS 15+. Servers run Linux, where
        // the deployment target is Swift 6.0+ regardless.
        .macOS(.v15)
    ],
    products: [
        .library(name: "Wire", targets: ["Wire"]),
        .plugin(name: "WireBuildPlugin", targets: ["WireBuildPlugin"]),
        .plugin(name: "WireContributorPlugin", targets: ["WireContributorPlugin"]),
    ],
    dependencies: [
        // Floor at 603.0.0 (Swift 6.3) so Wire can use SE-0491 module
        // selectors — both round-tripping module-qualified types through
        // codegen and recognising `@Wire::`-qualified macro attributes —
        // which the 601/602 (6.1/6.2) parsers don't have.
        .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"604.0.0")
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
        .plugin(
            name: "WireContributorPlugin",
            capability: .buildTool(),
            dependencies: ["WireGen"]
        ),
        .testTarget(
            name: "WireTests",
            dependencies: ["Wire"]
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
        // A same-package, Wire-aware library the IntegrationTests target
        // composes via cross-target source reading (iteration 7c). It opts
        // in with a `_WireExports.swift` marker and exposes a public
        // `@Singleton`; it has no plugin of its own — the consumer's plugin
        // re-parses its sources.
        .target(
            name: "WireTestLibrary",
            dependencies: ["Wire"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["Wire", "WireTestLibrary"],
            plugins: [.plugin(name: "WireBuildPlugin")]
        ),
    ]
)
