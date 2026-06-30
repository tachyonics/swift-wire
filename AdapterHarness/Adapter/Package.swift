// swift-tools-version: 6.3
import CompilerPluginSupport
import PackageDescription

// A minimal, non-shipped Wire adapter fixture backing the iteration-8 contract
// gate. It publishes `@RoutedBy` (a real member macro that generates
// `_wireRegister`) plus a `WireAdapterAnnotationV1` definition Wire discovers.
// It lives in its own package so the consumer activates it as an external
// `.product` — the same reason CompositionHarness's library is separate (a
// macro-using fixture inside swift-wire's own tests would form a circular
// package dependency).
let package = Package(
    name: "WireRouting",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireRouting", targets: ["WireRouting"])
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swiftlang/swift-syntax", "603.0.0"..<"604.0.0"),
    ],
    targets: [
        .macro(
            name: "WireRoutingMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "WireRouting",
            dependencies: [
                "WireRoutingMacros",
                .product(name: "Wire", package: "swift-wire"),
            ]
        ),
    ]
)
