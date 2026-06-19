import Wire

/// End-to-end exercise of collected and mapped multibindings: contributors
/// tagged `@Contributes` fan into an aggregate that a consumer `@Inject`s.
///
/// What this proves over the unit tests: the generated `_WireGraph`
/// actually *compiles* and bootstraps — the aggregate's `[a, b] as [P]`
/// literal type-checks against the contributors' concrete types, the
/// `withOrder:` ranks drive the array order, and the `atKey:` values key
/// the dictionary.

protocol Plugin {
    func label() -> String
}

enum PluginRegistry {
    static let ordered = CollectedKey<any Plugin>()
}

// Declared metrics-first, but `withOrder:` puts logging first.
@Singleton @Contributes(to: PluginRegistry.ordered, withOrder: 2)
struct MetricsPlugin: Plugin {
    func label() -> String { "metrics" }
}

@Singleton @Contributes(to: PluginRegistry.ordered, withOrder: 1)
struct LoggingPlugin: Plugin {
    func label() -> String { "logging" }
}

@Singleton
struct PluginHost {
    @Inject(PluginRegistry.ordered) var plugins: [any Plugin]
}

protocol Strategy {
    func run() -> String
}

enum StrategyRegistry {
    static let byName = MappedKey<String, any Strategy>()
}

@Singleton @Contributes(to: StrategyRegistry.byName, atKey: "fast")
struct FastStrategy: Strategy {
    func run() -> String { "fast" }
}

@Singleton @Contributes(to: StrategyRegistry.byName, atKey: "slow")
struct SlowStrategy: Strategy {
    func run() -> String { "slow" }
}

@Singleton
struct StrategyHost {
    @Inject(StrategyRegistry.byName) var strategies: [String: any Strategy]
}
