// swift-tools-version: 6.3
import PackageDescription

// The consumer for the iteration-8 adapter-contract gate. It depends on
// swift-wire (macros + build plugin) and on the external WireRouting adapter
// package, and applies WireBuildPlugin. Running the executable bootstraps the
// generated graph and asserts the `@RoutedBy` registration fired across the
// package boundary.
let package = Package(
    name: "AdapterHarnessConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(path: "../Adapter"),
    ],
    targets: [
        .executableTarget(
            name: "AdapterHarnessConsumer",
            dependencies: [
                .product(name: "Wire", package: "swift-wire"),
                .product(name: "WireRouting", package: "Adapter"),
            ],
            plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
        )
    ]
)
