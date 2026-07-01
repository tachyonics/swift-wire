import Wire
import WireRouting

/// A concrete `@Singleton` controller the `@RoutedBy` adapter registers with the
/// router. The adapter consumes it as `instance: Self`, which keeps it live —
/// no `allowUnused` needed.
@Singleton
@RoutedBy(Router.self)
struct SimpleController {
    @Inject init() {}
}

protocol RoutingController {}
protocol Backend: Sendable {}
struct InMemoryBackend: Backend {}

/// A *fully lifted* controller: `@Singleton(as:)` keys it by an opaque identity
/// `some RoutingController`, so it lifts a `_WireGraph` parameter of its own.
/// Generic over a constrained backend injected as a bare parameter (bridged to
/// the `some Backend` leaf). Proves `@RoutedBy` resolves an opaque bare-`some P`
/// node — read via the concrete-reference map, not the opaque key.
@Singleton(as: RoutingController.self)
@RoutedBy(Router.self)
struct LiftedController<B: Backend>: RoutingController {
    @Inject init(backend: B) {}
}

/// A *partially lifted* (lift-the-minimum) controller: a plain generic
/// `@Singleton` keyed by its structural identity `StructuralController<some
/// Backend>`, so it lifts no parameter of its own — it's a nested
/// `StructuralController<T0>` field reusing the backend's parameter. Proves
/// `@RoutedBy` resolves a structural node through the same concrete-reference map.
@Singleton
@RoutedBy(Router.self)
struct StructuralController<B: Backend>: RoutingController {
    @Inject init(backend: B) {}
}

enum Wiring {
    // The router is the registration's collaborator, not a binding consumed by a
    // derivation edge — what `_wireRegister` does with it is the adapter's own
    // logic, which Wire can't see — so it carries `allowUnused`. (It's read off
    // the graph below to assert the registration ran.)
    @Provides(allowUnused: true)
    static let router = Router()

    // The composition-root leaf for the lifted controller's backend.
    @Provides
    static let backend: some Backend = InMemoryBackend()
}

// WireBuildPlugin runs on this target: it discovers the `@RoutedBy` definition
// from the activated WireRouting library, validates the registration's
// dependencies against the graph, and emits
// `SimpleController._wireRegister(instance:router:)` in the bootstrap. Running
// it proves the adapter contract end-to-end: definition discovery across the
// package boundary, use-site resolution, and post-construction registration.
let graph = try await _Wire.bootstrap()
precondition(
    graph.router.routes.contains("SimpleController"),
    "concrete @RoutedBy registration did not run"
)
// Each lifted controller records under its concrete type — the fully-lifted
// (`LiftedController<…>`) and the partially-lifted (`StructuralController<…>`) —
// so match on the prefix.
precondition(
    graph.router.routes.contains { $0.hasPrefix("LiftedController") },
    "fully-lifted @RoutedBy registration did not run"
)
precondition(
    graph.router.routes.contains { $0.hasPrefix("StructuralController") },
    "partially-lifted @RoutedBy registration did not run"
)
print("OK: @RoutedBy registration emitted, validated, and executed (concrete + full + partial lifting)")
