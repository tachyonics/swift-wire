import Wire

/// End-to-end exercise of `@Inject weak let` — SE-0481's immutable weak
/// storage as a *constructor-injected*, non-owning reference.
///
/// Unlike `@Inject weak var` (post-construct delivery, the cycle-breaker),
/// a `weak let` is delivered at *init* — the single write a `let` allows.
/// The synthesised init takes `telemetry: Telemetry?` and assigns it; the
/// relationship is acyclic (Telemetry doesn't reference Dashboard back),
/// so it's an ordinary init-time edge.
///
/// This is the canonical `weak let` use: a non-owning reference to a
/// container-owned, app-lifetime dependency. Because `Telemetry` is a
/// `@Singleton`, the generated graph retains it strongly, so
/// `dashboard.telemetry` stays non-nil even though Dashboard's hold is
/// weak — the weak is for leak-safety / immutability, not lifetime.
///
/// The load-bearing thing this proves over the unit tests: the
/// macro-generated `init(telemetry: Telemetry?) { self.telemetry =
/// telemetry }` actually *compiles* against `weak let` storage (the unit
/// macro test only string-compares the generated text).
@Singleton
package final class Telemetry {
    package let id = "telemetry"
}

@Singleton
package final class Dashboard {
    @Inject package weak let telemetry: Telemetry?

    package func describeTelemetry() -> String {
        guard let telemetry else { return "telemetry unset" }
        return "telemetry id: \(telemetry.id)"
    }
}
