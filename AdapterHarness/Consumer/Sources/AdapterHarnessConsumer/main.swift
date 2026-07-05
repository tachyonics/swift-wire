import Wire
import WireRouting

// `@RoutedBy` controllers — `@Singleton` bindings the adapter aliases into
// `@Contributes(to: RoutingKeys.controllers)`, plus a `Controller` conformance the
// `@RoutedBy` macro adds.
@Singleton @RoutedBy struct SimpleController { @Inject init() {} }
@Singleton @RoutedBy struct AnotherController { @Inject init() {} }
@Singleton @RoutedBy struct ThirdController { @Inject init() {} }

/// Consumes the collated controllers (keyed to the `RoutingKeys.controllers`
/// CollectedKey) — keeps the contribution live and lets us assert the collation
/// ran across the package boundary.
@Singleton(allowUnused: true)
struct Registry {
    @Inject(RoutingKeys.controllers) var controllers: [any Controller]
}

// WireBuildPlugin runs on this target: it discovers the `@RoutedBy` definition from
// the activated WireRouting library, reads each `@RoutedBy` use-site as
// `@Contributes(to: RoutingKeys.controllers)`, and collates the three controllers
// into the `[any Controller]` the Registry injects. Running it proves the
// contribution-alias contract end-to-end across the package boundary.
let graph = try await Wire.bootstrap()
precondition(
    graph.registry.controllers.count == 3,
    "expected 3 @RoutedBy controllers collated, got \(graph.registry.controllers.count)"
)
print("OK: @RoutedBy contribution alias collated 3 controllers across the package boundary")
