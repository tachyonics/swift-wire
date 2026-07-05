import Wire
import WireRouting

// A concrete `@HarnessRoute` controller — `@Singleton`, aliased into
// `@Contributes(to: RoutingKeys.controllers)`, with a `Controller` conformance the
// `@HarnessRoute` macro adds.
@Singleton @HarnessRoute struct SimpleController { @Inject init() {} }

protocol RoutingController {}
protocol Backend: Sendable {}
struct InMemoryBackend: Backend {}

/// A *fully lifted* controller: `@Singleton(as:)` keys it by an opaque identity
/// `some RoutingController`, so it lifts a `_WireGraph` parameter of its own;
/// generic over a constrained backend injected as a bare parameter. Proves a
/// contribution collates from an opaque-lifted, generic binding — the concrete type
/// conforms to `Controller` (added by `@HarnessRoute`) and collates as `any Controller`.
@Singleton(as: RoutingController.self) @HarnessRoute
struct LiftedController<B: Backend>: RoutingController {
    @Inject init(backend: B) {}
}

/// A *partially lifted* controller: a plain generic `@Singleton` keyed by its
/// structural identity `StructuralController<some Backend>`, lifting no parameter of
/// its own. Proves a contribution collates from a structural generic binding.
@Singleton @HarnessRoute
struct StructuralController<B: Backend>: RoutingController {
    @Inject init(backend: B) {}
}

enum Wiring {
    // The composition-root leaf for the lifted/structural controllers' backend.
    @Provides static let backend: some Backend = InMemoryBackend()
}

/// Consumes the collated controllers (keyed to the `RoutingKeys.controllers`
/// CollectedKey) — keeps the contribution live and lets us assert the collation.
@Singleton(allowUnused: true)
struct Registry {
    @Inject(RoutingKeys.controllers) var controllers: [any Controller]
    var names: [String] { controllers.map { String(describing: type(of: $0)) } }
}

// WireBuildPlugin runs on this target: it discovers the `@HarnessRoute` definition
// from the activated WireRouting library, reads each use-site as `@Contributes(to:
// RoutingKeys.controllers)`, and collates the three controllers into the
// `[any Controller]` the Registry injects — proving the contribution-alias contract
// across the package boundary *and* across binding shapes (concrete, fully-lifted,
// partially-lifted).
let graph = try await Wire.bootstrap()
let names = graph.registry.names
precondition(names.count == 3, "expected 3 controllers collated, got \(names.count): \(names)")
precondition(names.contains { $0.hasPrefix("SimpleController") }, "concrete controller not collated")
precondition(names.contains { $0.hasPrefix("LiftedController") }, "fully-lifted controller not collated")
precondition(names.contains { $0.hasPrefix("StructuralController") }, "partially-lifted controller not collated")
print("OK: @HarnessRoute collated concrete + fully-lifted + partially-lifted controllers")
