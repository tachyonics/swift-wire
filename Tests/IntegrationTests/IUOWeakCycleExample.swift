import Wire

/// End-to-end exercise of `@Inject weak var x: T!` — the IUO spelling of
/// weak cycle-breaking (the IBOutlet idiom). Mirrors `WeakCycleExample`
/// (which uses `T?`); the `!` vs `?` is purely ergonomic.
///
///   - `Hub` injects `Spoke` strongly (eager construction).
///   - `Spoke` injects `Hub` weakly via `@Inject weak var hub: Hub!`.
///
/// Without the weak modifier this is a strong cycle (Hub → Spoke → Hub)
/// the build plugin rejects. The weak edge is excluded from cycle
/// detection: topo sort orders Spoke first, then Hub, and the generated
/// bootstrap post-init-assigns `spoke.hub = hub`. The IUO just lets
/// `hub` read as a non-optional `Hub` at the use site (implicit unwrap)
/// instead of `Hub?`.
///
/// What this proves over the unit tests: the matcher's `T!` → optional
/// normalization works through the whole pipeline, AND the generated
/// `spoke.hub = hub` compiles against `weak var hub: Hub!` storage (the
/// old discovery `?`-strip handled only `T?`, never `T!`).
@Singleton
package final class Hub {
    package let spoke: Spoke

    @Inject
    package init(spoke: Spoke) {
        self.spoke = spoke
    }
}

@Singleton
package final class Spoke {
    @Inject package weak var hub: Hub!

    package func describeHub() -> String {
        // `hub` accessed as a non-optional `Hub` (IUO implicit unwrap):
        // it's alive because Hub holds Spoke and the graph holds Hub.
        "hub owns this spoke: \(hub.spoke === self)"
    }
}
