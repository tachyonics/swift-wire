import Wire
import WireRouting

/// A `@Singleton` controller the `@RoutedBy` adapter registers with the router.
/// `allowUnused` because in M1 the dead-binding check doesn't yet count an
/// adapter registration as consumption — the controller is "used" only by its
/// generated `_wireRegister`.
@Singleton(allowUnused: true)
@RoutedBy(Router.self)
struct SimpleController {
    @Inject init() {}
}

enum Wiring {
    // Read off the graph by the registration (and asserted below); the
    // dead-binding check doesn't see the adapter's use of it, hence allowUnused.
    @Provides(allowUnused: true)
    static let router = Router()
}

// WireBuildPlugin runs on this target: it discovers the `@RoutedBy` definition
// from the activated WireRouting library, validates the registration's
// dependencies against the graph, and emits
// `SimpleController._wireRegister(instance:router:)` in the bootstrap. Running
// it proves the adapter contract end-to-end: definition discovery across the
// package boundary, use-site resolution, and post-construction registration.
let graph = try await _WireGraph.bootstrap()
precondition(
    graph.router.routes.contains("SimpleController"),
    "adapter registration did not run"
)
print("OK: @RoutedBy registration emitted, validated, and executed")
