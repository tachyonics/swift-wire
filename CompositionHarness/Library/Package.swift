// swift-tools-version: 6.3
import PackageDescription

// An external Wire-aware library package, used by the sibling Consumer
// package to exercise cross-*package* composition (iteration 7g). It lives
// in its own package (not a target of swift-wire) precisely so the
// consumer activates it as a `.product` from an external package — the
// `.product` path 7d can't test from within swift-wire's own `swift test`
// (a macro-using fixture that swift-wire depended on would form a cycle).
let package = Package(
    name: "WireHarnessLibrary",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WireHarnessLibrary", targets: ["WireHarnessLibrary"])
    ],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        // No build plugin: the library is consumed, not bootstrapped — the
        // consumer's plugin re-parses these sources (M1). The library opts
        // into composition with its `_WireExports.swift` marker.
        .target(
            name: "WireHarnessLibrary",
            dependencies: [.product(name: "Wire", package: "swift-wire")]
        )
    ]
)
