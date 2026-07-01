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

/// A *lifted* controller: keyed in the graph as `some RoutingController` via
/// `@Singleton(as:)`, generic over a constrained backend injected as a bare
/// parameter (bridged to the `some Backend` leaf). Proves `@RoutedBy` resolves
/// its instance by the opaque identity, not the concrete `LiftedController`.
@Singleton(as: RoutingController.self)
@RoutedBy(Router.self)
struct LiftedController<B: Backend>: RoutingController {
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
// The lifted controller records under its concrete type (`LiftedController<…>`),
// so match on the prefix.
precondition(
    graph.router.routes.contains { $0.hasPrefix("LiftedController") },
    "lifted @RoutedBy registration did not run"
)
print("OK: @RoutedBy registration emitted, validated, and executed (concrete + lifted)")
