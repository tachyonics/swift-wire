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
/// `@unchecked Sendable` because `weak var coordinator` is mutable
/// (Swift requires weak storage to be `var`). Real adopters of this
/// pattern would typically use `@MainActor` isolation (UIKit/SwiftUI
/// coordinator pattern) or accept the unchecked label after auditing
/// concurrency. The test fixture stays single-threaded so the audit
/// is trivial — the weak slot is set once during bootstrap and read
/// from test code thereafter.
@Singleton
package final class Coordinator: @unchecked Sendable {
    package let view: View

    @Inject
    package init(view: View) {
        self.view = view
    }
}

@Singleton
package final class View: @unchecked Sendable {
    @Inject package weak var coordinator: Coordinator?

    package func describeCoordinator() -> String {
        guard let coordinator else { return "coordinator unset" }
        return "coordinator owns this view: \(coordinator.view === self)"
    }
}
