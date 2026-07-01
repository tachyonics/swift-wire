import Wire
import WireRouting

/// A `@Singleton` controller the `@RoutedBy` adapter registers with the router.
/// The adapter consumes it as `instance: Self`, which keeps it live — no
/// `allowUnused` needed.
@Singleton
@RoutedBy(Router.self)
struct SimpleController {
    @Inject init() {}
}

enum Wiring {
    // The router is the registration's collaborator, not a binding consumed by a
    // derivation edge — what `_wireRegister` does with it is the adapter's own
    // logic, which Wire can't see — so it carries `allowUnused`. (It's read off
    // the graph below to assert the registration ran.)
    @Provides(allowUnused: true)
    static let router = Router()
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
    "adapter registration did not run"
)
print("OK: @RoutedBy registration emitted, validated, and executed")
