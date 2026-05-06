import Wire

/// A simple value supplied by a module-scope `@Provides let`. Exercises
/// the most common `@Provides` shape — a primitive the consumer wires
/// in by hand because the graph can't construct it on its own.
struct AppName: Sendable {
    let value: String
}

@Provides let appName: AppName = AppName(value: "IntegrationTests")
