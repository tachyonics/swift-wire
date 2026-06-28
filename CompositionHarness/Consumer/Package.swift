// swift-tools-version: 6.3
import PackageDescription

// The consumer package for the iteration-7g composition gate. It depends
// on swift-wire (for the macros + build plugin) and on the external
// WireHarnessLibrary package, and applies WireBuildPlugin. Depending on a
// Wire-aware external library is what activates it (7d) — there is no
// `.activating(...)` call. Running the executable bootstraps the generated
// graph and asserts the library's bindings composed across the package
// boundary.
let package = Package(
    name: "WireHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../Library"),
    ],
    targets: [
        .executableTarget(
            name: "WireHarnessConsumer",
            dependencies: [
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "WireHarnessLibrary", package: "Library"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
