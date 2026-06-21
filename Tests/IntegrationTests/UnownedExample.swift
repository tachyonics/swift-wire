import Wire

/// End-to-end exercise of `@Inject unowned let` — a non-owning,
/// NON-optional, constructor-injected reference (the non-optional sibling
/// of `weak let`).
///
/// Unlike `weak var`, `unowned` can't be a cycle-breaker: its storage is
/// non-optional, so it must be initialised at `init`, and therefore can't
/// be deferred post-construct. So this is acyclic — `Sensor` is built
/// first and the graph retains it strongly, so the unowned hold stays
/// valid. The non-optional `let` gives bare access (no `?`/`.get()`) for
/// a dependency the container is known to keep alive.
///
/// What this proves over the unit tests: the macro-generated
/// `init(sensor: Sensor) { self.sensor = sensor }` actually *compiles*
/// against `unowned let` storage, and the non-optional access works.
@Singleton
package final class Sensor {
    package let id = "sensor"
}

@Singleton(allowUnused: true)
package final class Monitor {
    @Inject package unowned let sensor: Sensor

    package func describeSensor() -> String {
        "sensor id: \(sensor.id)"
    }
}
