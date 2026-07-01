import Wire

/// End-to-end fixture for generic specialisation. A parameterised factory
/// `@Provides func makeContainer<T>` and a concrete consumer asking for
/// `Container<DataPoint>`. The build plugin specialises the factory with
/// `T = DataPoint`, substitutes the dep type through, and emits a concrete
/// `Container<DataPoint>` binding the consumer resolves against — without a
/// separate `@Provides` per instantiation. (A generic `@Singleton` can't do
/// this: it must be a single instance — see the invalid-generic-singleton
/// diagnostic — so parameterised, multi-instance families are `@Provides func`.)
struct DataPoint: Sendable {
    let value: Int
}

// Consumed via Container<DataPoint> specialisation, which the
// first-order dead-binding analysis doesn't track.
@Provides(allowUnused: true)
let dataPoint: DataPoint = DataPoint(value: 42)

struct Container<T: Sendable>: Sendable {
    let item: T

    func describe() -> String {
        "Container(\(String(describing: item)))"
    }
}

@Provides
func makeContainer<T: Sendable>(item: T) -> Container<T> {
    Container(item: item)
}

@Singleton(allowUnused: true)
struct GenericConsumer {
    @Inject var container: Container<DataPoint>

    func describe() -> String {
        container.describe()
    }
}
