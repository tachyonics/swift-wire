import Wire

/// End-to-end fixture for sitting 2b's generic specialisation.
/// Declares a generic `@Singleton Container<T>` and a concrete
/// consumer asking for `Container<DataPoint>`. The build plugin
/// should specialise the generic with `T = DataPoint`, substitute the
/// dep type through, and emit a concrete `Container<DataPoint>`
/// binding the consumer can resolve against — without the user
/// having to register a separate `@Provides` for each instantiation.
struct DataPoint: Sendable {
    let value: Int
}

// Consumed via Container<DataPoint> specialisation, which the
// first-order dead-binding analysis doesn't track.
@Provides(allowUnused: true)
let dataPoint: DataPoint = DataPoint(value: 42)

@Singleton
struct Container<T: Sendable>: Sendable {
    @Inject var item: T

    func describe() -> String {
        "Container(\(String(describing: item)))"
    }
}

@Singleton(allowUnused: true)
struct GenericConsumer {
    @Inject var container: Container<DataPoint>

    func describe() -> String {
        container.describe()
    }
}
