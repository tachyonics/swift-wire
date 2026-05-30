import Wire

/// End-to-end exercise of `@Inject weak var` cycle-breaking. Two
/// `@Singleton` classes mutually reference each other:
///   - `Coordinator` injects `View` strongly (eager construction).
///   - `View` injects `Coordinator` weakly (deferred assignment).
///
/// Without the weak modifier, the graph would have a strong cycle
/// (View → Coordinator → View) and the build plugin would reject
/// the input. With the weak modifier on View's side, the graph
/// retains only Coordinator → View as a strong edge; topo sort
/// orders View first, then Coordinator. The generated bootstrap
/// constructs both, then post-init-assigns `view.coordinator = coordinator`.
///
/// Both runtime relationships are visible after bootstrap:
///   - `coordinator.view === view` (strong, established at init).
///   - `view.coordinator === coordinator` (weak, established post-init).
///
/// No `Sendable` conformance on either class — `weak var coordinator`
/// is mutable storage that defeats auto-derivation, and the test
/// fixture doesn't cross any actor / Task isolation boundary so
/// `Sendable` isn't required. The generated `_WireGraph` becomes
/// non-Sendable too (auto-derivation propagates the constraint),
/// which is also fine: this test holds the graph in a single test
/// task and never sends it elsewhere.
@Singleton
package final class Coordinator {
    package let view: View

    @Inject
    package init(view: View) {
        self.view = view
    }
}

@Singleton
package final class View {
    @Inject package weak var coordinator: Coordinator?

    package func describeCoordinator() -> String {
        guard let coordinator else { return "coordinator unset" }
        return "coordinator owns this view: \(coordinator.view === self)"
    }
}
