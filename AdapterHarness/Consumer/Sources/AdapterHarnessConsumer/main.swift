import Wire
import WireRouting

// `@HarnessRoute` controllers — `@Singleton` bindings the adapter aliases into
// `@Contributes(to: RoutingKeys.controllers)`, plus a `Controller` conformance the
// `@HarnessRoute` macro adds.
@Singleton @HarnessRoute struct SimpleController { @Inject init() {} }
@Singleton @HarnessRoute struct AnotherController { @Inject init() {} }
@Singleton @HarnessRoute struct ThirdController { @Inject init() {} }

/// Consumes the collated controllers (keyed to the `RoutingKeys.controllers`
/// CollectedKey) — keeps the contribution live and lets us assert the collation
/// ran across the package boundary.
@Singleton(allowUnused: true)
struct Registry {
    @Inject(RoutingKeys.controllers) var controllers: [any Controller]
}

// WireBuildPlugin runs on this target: it discovers the `@HarnessRoute` definition
// from the activated WireRouting library, reads each `@HarnessRoute` use-site as
// `@Contributes(to: RoutingKeys.controllers)`, and collates the three controllers
// into the `[any Controller]` the Registry injects. Running it proves the
// contribution-alias contract end-to-end across the package boundary.
let graph = try await Wire.bootstrap()
precondition(
    graph.registry.controllers.count == 3,
    "expected 3 @HarnessRoute controllers collated, got \(graph.registry.controllers.count)"
)
print("OK: @HarnessRoute contribution alias collated 3 controllers across the package boundary")
